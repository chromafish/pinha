// Keyboard layer for the console frame. Every shortcut here is printed in the
// status bar; nothing is hidden in a menu.
(function () {
  var rows = function () {
    return Array.prototype.slice.call(document.querySelectorAll("[data-row]"));
  };

  var index = -1;

  function select(next) {
    var all = rows();
    if (all.length === 0) return;

    index = Math.max(0, Math.min(next, all.length - 1));

    all.forEach(function (row, i) {
      if (i === index) {
        row.setAttribute("aria-selected", "true");
        row.scrollIntoView({ block: "nearest" });
      } else {
        row.removeAttribute("aria-selected");
      }
    });
  }

  function open() {
    var row = rows()[index];
    if (!row) return;
    var link = row.querySelector("a[href]");
    if (link) window.location.href = link.href;
  }

  function typing(target) {
    return target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA");
  }

  Array.prototype.slice
    .call(document.querySelectorAll("[data-expandable-panel]"))
    .forEach(function (panel) {
      var button = panel.querySelector("[data-expand-toggle]");
      var label = panel.querySelector("[data-expand-label]");
      if (!button || !label) return;

      button.addEventListener("click", function () {
        var expanded = button.getAttribute("aria-expanded") === "true";
        panel.classList.toggle("is-expanded", !expanded);
        button.setAttribute("aria-expanded", String(!expanded));
        label.textContent = expanded ? "Show all" : "Collapse";
      });
    });

  document.addEventListener("keydown", function (event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    if (typing(event.target)) {
      if (event.key === "Escape") event.target.blur();
      return;
    }

    switch (event.key) {
      case "j":
        event.preventDefault();
        select(index + 1);
        break;
      case "k":
        event.preventDefault();
        select(index - 1);
        break;
      case "Enter":
        event.preventDefault();
        open();
        break;
      case "u":
        var up = document.querySelector("[data-up]");
        if (up) {
          event.preventDefault();
          window.location.href = up.getAttribute("data-up");
        }
        break;
      case "/":
        var field = document.querySelector("[data-focus]");
        if (field) {
          event.preventDefault();
          field.focus();
        }
        break;
    }
  });
})();
