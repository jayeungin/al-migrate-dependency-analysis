document.addEventListener("DOMContentLoaded", function () {
    initSearch();
    initFilters();
    initSort();
});

function initSearch() {
    var searchInput = document.getElementById("pkg-search");
    if (!searchInput) return;

    searchInput.addEventListener("input", function () {
        var query = this.value.toLowerCase();
        var rows = document.querySelectorAll("#package-table tbody tr");
        rows.forEach(function (row) {
            var name = row.getAttribute("data-name") || "";
            var matchesSearch = !query || name.indexOf(query) !== -1;
            var activeFilter = document.querySelector(".filter-btn.active");
            var filter = activeFilter ? activeFilter.getAttribute("data-filter") : "all";
            var matchesFilter = filter === "all" || row.getAttribute("data-risk") === filter;
            row.classList.toggle("hidden", !(matchesSearch && matchesFilter));
        });
    });
}

function initFilters() {
    var buttons = document.querySelectorAll(".filter-btn");
    buttons.forEach(function (btn) {
        btn.addEventListener("click", function () {
            buttons.forEach(function (b) { b.classList.remove("active"); });
            btn.classList.add("active");

            var filter = btn.getAttribute("data-filter");
            var searchInput = document.getElementById("pkg-search");
            var query = searchInput ? searchInput.value.toLowerCase() : "";
            var rows = document.querySelectorAll("#package-table tbody tr");

            rows.forEach(function (row) {
                var risk = row.getAttribute("data-risk");
                var name = row.getAttribute("data-name") || "";
                var matchesFilter = filter === "all" || risk === filter;
                var matchesSearch = !query || name.indexOf(query) !== -1;
                row.classList.toggle("hidden", !(matchesFilter && matchesSearch));
            });
        });
    });
}

function initSort() {
    var headers = document.querySelectorAll("#package-table th.sortable");
    headers.forEach(function (th) {
        th.addEventListener("click", function () {
            var sortKey = th.getAttribute("data-sort");
            var table = document.getElementById("package-table");
            var tbody = table.querySelector("tbody");
            var rows = Array.from(tbody.querySelectorAll("tr"));
            var ascending = th.classList.contains("sort-asc");

            headers.forEach(function (h) {
                h.classList.remove("sort-asc", "sort-desc");
            });

            if (ascending) {
                th.classList.add("sort-desc");
            } else {
                th.classList.add("sort-asc");
            }

            rows.sort(function (a, b) {
                var aVal, bVal;
                if (sortKey === "name") {
                    aVal = a.getAttribute("data-name") || "";
                    bVal = b.getAttribute("data-name") || "";
                } else if (sortKey === "status") {
                    aVal = a.getAttribute("data-risk") || "";
                    bVal = b.getAttribute("data-risk") || "";
                } else {
                    aVal = "";
                    bVal = "";
                }
                var cmp = aVal.localeCompare(bVal);
                return ascending ? -cmp : cmp;
            });

            rows.forEach(function (row) {
                tbody.appendChild(row);
            });
        });
    });
}

function exportJSON() {
    if (typeof REPORT_DATA === "undefined") return;
    var blob = new Blob([JSON.stringify(REPORT_DATA, null, 2)], { type: "application/json" });
    downloadBlob(blob, "migration-report.json");
}

function exportCSV() {
    if (typeof REPORT_DATA === "undefined") return;
    var lines = ["Package,Installed Version,Status,Risk,RHEL Package,Notes"];
    REPORT_DATA.packages.forEach(function (pkg) {
        lines.push([
            csvEscape(pkg.name),
            csvEscape(pkg.installed_version),
            csvEscape(pkg.status),
            csvEscape(pkg.risk),
            csvEscape(pkg.rhel_package || ""),
            csvEscape(pkg.notes)
        ].join(","));
    });
    var blob = new Blob([lines.join("\n")], { type: "text/csv" });
    downloadBlob(blob, "migration-report.csv");
}

function csvEscape(val) {
    val = String(val);
    if (val.indexOf(",") !== -1 || val.indexOf('"') !== -1 || val.indexOf("\n") !== -1) {
        return '"' + val.replace(/"/g, '""') + '"';
    }
    return val;
}

function downloadBlob(blob, filename) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}
