import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";

const nodeStates = ["pending", "running", "succeeded", "failed", "rejected", "accepted", "waiting"];

const GraphBoard = {
  mounted() {
    this.svg = this.el.querySelector("svg");
    if (!this.svg) return;
    this.badgePayloads = new Map();
    this.placeBadges = this.placeBadges.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);

    if (window.svgPanZoom) {
      this.panZoom = window.svgPanZoom(this.svg, {
        zoomEnabled: true,
        panEnabled: true,
        controlIconsEnabled: false,
        fit: true,
        center: true,
        minZoom: 0.2,
        maxZoom: 8,
        dblClickZoomEnabled: false,
        onZoom: this.placeBadges,
        onPan: this.placeBadges
      });
    }

    this.el.addEventListener("dblclick", () => this.reset());
    document.addEventListener("keydown", this.handleKeydown);
    window.addEventListener("resize", this.placeBadges);

    this.svg.querySelectorAll("g.tractor-node[data-node-id]").forEach((node) => {
      const nodeId = node.getAttribute("data-node-id");
      node.setAttribute("role", "button");
      node.setAttribute("tabindex", "0");
      node.setAttribute("aria-label", `Node ${nodeId}`);

      node.addEventListener("click", (event) => {
        event.stopPropagation();
        this.pushEvent("select_node", { "node-id": nodeId });
      });

      node.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        this.pushEvent("select_node", { "node-id": nodeId });
      });
    });

    this.handleEvent("graph:node_state", ({ node_id, state }) => {
      this.applyState(node_id, state);
    });

    this.handleEvent("graph:selected", ({ node_id }) => {
      this.applySelected(node_id);
    });

    this.handleEvent("graph:badges", (payload) => {
      this.applyBadges(payload);
    });

    this.handleEvent("graph:edge_taken", (payload) => {
      this.pulseEdge(payload);
    });

    window.requestAnimationFrame(this.placeBadges);
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleKeydown);
    window.removeEventListener("resize", this.placeBadges);
    if (this.panZoom) this.panZoom.destroy();
  },

  handleKeydown(event) {
    if (event.key === "Escape") {
      if (document.querySelector(".help-overlay")) {
        this.pushEvent("toggle_help", {});
      }
      this.pushEvent("clear_selection", {});
      return;
    }

    if (event.key === "?" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      this.pushEvent("toggle_help", {});
    }
  },

  reset() {
    if (!this.panZoom) return;
    this.panZoom.reset();
    this.panZoom.fit();
    this.panZoom.center();
  },

  applyState(nodeId, state) {
    const node = this.findNode(nodeId);
    if (!node) return;
    node.classList.remove(...nodeStates);
    if (state) node.classList.add(state);

    const payload = this.badgePayloads.get(nodeId);
    if (payload) this.applyBadges({ ...payload, state });
  },

  applySelected(nodeId) {
    this.svg.querySelectorAll("g.tractor-node.is-selected").forEach((node) => {
      node.classList.remove("is-selected");
    });

    const selected = this.findNode(nodeId);
    if (selected) selected.classList.add("is-selected");
  },

  placeBadges() {
    if (!this.svg) return;

    this.svg.querySelectorAll("g.tractor-node[data-node-id]").forEach((node) => {
      const badge = this.ensureBadge(node);
      if (!badge) return;

      try {
        const previousDisplay = badge.style.display;
        badge.style.display = "none";
        const box = node.getBBox();
        badge.style.display = previousDisplay;
        // Below the node, horizontally centered. Badge lines stack below the shape.
        badge.setAttribute(
          "transform",
          `translate(${box.x + box.width / 2} ${box.y + box.height + 10})`
        );
      } catch (_error) {
        badge.style.display = "";
        badge.setAttribute("visibility", "hidden");
      }
    });
  },

  ensureBadge(node) {
    let badge = node.querySelector(":scope > g.tractor-badges");
    if (badge) return badge;

    const svgNs = "http://www.w3.org/2000/svg";
    badge = document.createElementNS(svgNs, "g");
    badge.classList.add("tractor-badges");
    badge.setAttribute("aria-label", "");

    const duration = document.createElementNS(svgNs, "text");
    duration.setAttribute("x", "0");
    duration.setAttribute("y", "0");
    duration.setAttribute("dominant-baseline", "hanging");
    duration.setAttribute("text-anchor", "middle");

    const durationText = document.createElementNS(svgNs, "tspan");
    durationText.classList.add("tractor-badge-duration");
    duration.appendChild(durationText);

    const iterations = document.createElementNS(svgNs, "tspan");
    iterations.classList.add("tractor-badge-iterations");
    iterations.setAttribute("dx", "6");
    duration.appendChild(iterations);

    const tokens = document.createElementNS(svgNs, "text");
    tokens.classList.add("tractor-badge-tokens");
    tokens.setAttribute("x", "0");
    tokens.setAttribute("y", "11");
    tokens.setAttribute("dominant-baseline", "hanging");
    tokens.setAttribute("text-anchor", "middle");

    const cumulative = document.createElementNS(svgNs, "text");
    cumulative.classList.add("tractor-badge-cumulative");
    cumulative.setAttribute("x", "0");
    cumulative.setAttribute("y", "22");
    cumulative.setAttribute("dominant-baseline", "hanging");
    cumulative.setAttribute("text-anchor", "middle");

    badge.append(duration, tokens, cumulative);
    node.appendChild(badge);
    return badge;
  },

  applyBadges({ node_id: nodeId, duration, tokens, iterations, cumulative, state }) {
    if (!nodeId) return;

    const payload = { node_id: nodeId, duration, tokens, iterations, cumulative, state };
    this.badgePayloads.set(nodeId, payload);

    const node = this.findNode(nodeId);
    if (!node) return;

    const badge = this.ensureBadge(node);
    if (!badge) return;

    badge.querySelector(".tractor-badge-duration").textContent = duration || "";
    badge.querySelector(".tractor-badge-tokens").textContent = tokens || "";
    const iterationsEl = badge.querySelector(".tractor-badge-iterations");
    iterationsEl.textContent = iterations || "";
    iterationsEl.setAttribute("dx", iterations && duration ? "6" : "0");
    badge.querySelector(".tractor-badge-cumulative").textContent =
      cumulative ? `Σ ${cumulative}` : "";
    badge.setAttribute(
      "aria-label",
      [
        duration && `duration ${duration}`,
        tokens && `tokens ${tokens}`,
        iterations && `iterations ${iterations}`,
        cumulative && `cumulative ${cumulative}`
      ].filter(Boolean).join(", ")
    );

    // Show badges once a node has terminal data OR has run at least once
    // (iterations badge carries enough signal mid-loop to be worth surfacing).
    const hasContent = Boolean(duration || tokens || iterations || cumulative);
    const terminal = state === "succeeded" || state === "failed" ||
                     state === "accepted" || state === "rejected";
    badge.classList.toggle("is-visible", (terminal || Boolean(iterations)) && hasContent);
    this.placeBadges();
  },

  pulseEdge({ from, to }) {
    if (!from || !to || !this.svg) return;
    const edge = this.svg.querySelector(
      `g.tractor-edge[data-from="${CSS.escape(from)}"][data-to="${CSS.escape(to)}"]`
    );
    if (!edge) return;
    edge.classList.remove("is-taken");
    edge.getBoundingClientRect();
    edge.classList.add("is-taken");
  },

  findNode(nodeId) {
    if (!nodeId || !this.svg) return null;
    return this.svg.querySelector(`g.tractor-node[data-node-id="${CSS.escape(nodeId)}"]`);
  }
};

const ThemeToggle = {
  mounted() {
    this.updateAria();
    this.el.addEventListener("click", () => this.toggle());
  },

  currentTheme() {
    return document.documentElement.getAttribute("data-theme") || "light";
  },

  toggle() {
    const next = this.currentTheme() === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try {
      localStorage.setItem("tractor-theme", next);
    } catch (_) {}
    this.updateAria();
  },

  updateAria() {
    const current = this.currentTheme();
    this.el.setAttribute("aria-label", "Toggle dark mode");
    this.el.setAttribute("title", current === "dark" ? "Theme: dark" : "Theme: light");
    this.el.setAttribute("aria-pressed", current === "dark" ? "true" : "false");
  }
};

const Resizer = {
  mounted() {
    this.panel = this.el.dataset.panel; // "left" or "right"
    this.shell = document.querySelector(".tractor-shell");
    this.varName = this.panel === "left" ? "--left-width" : "--right-width";
    this.storageKey =
      this.panel === "left" ? "tractor-left-panel-width" : "tractor-right-panel-width";
    this.onDown = this.onDown.bind(this);
    this.onMove = this.onMove.bind(this);
    this.onUp = this.onUp.bind(this);
    this.restoreWidth();
    this.el.addEventListener("mousedown", this.onDown);
  },

  destroyed() {
    document.removeEventListener("mousemove", this.onMove);
    document.removeEventListener("mouseup", this.onUp);
  },

  onDown(event) {
    event.preventDefault();
    this.startX = event.clientX;
    const computed = getComputedStyle(this.shell).getPropertyValue(this.varName);
    this.startWidth = parseInt(computed, 10) || 320;
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", this.onMove);
    document.addEventListener("mouseup", this.onUp);
  },

  onMove(event) {
    const dx = event.clientX - this.startX;
    const delta = this.panel === "left" ? dx : -dx;
    const next = Math.max(240, Math.min(720, this.startWidth + delta));
    this.shell.style.setProperty(this.varName, next + "px");
  },

  onUp() {
    this.persistWidth();
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    document.removeEventListener("mousemove", this.onMove);
    document.removeEventListener("mouseup", this.onUp);
  },

  restoreWidth() {
    try {
      const stored = parseInt(localStorage.getItem(this.storageKey), 10);
      if (!Number.isFinite(stored)) return;
      const next = Math.max(240, Math.min(720, stored));
      this.shell.style.setProperty(this.varName, next + "px");
    } catch (_) {}
  },

  persistWidth() {
    try {
      const value = parseInt(getComputedStyle(this.shell).getPropertyValue(this.varName), 10);
      if (!Number.isFinite(value)) return;
      localStorage.setItem(this.storageKey, value.toString());
    } catch (_) {}
  }
};

const VerticalResizer = {
  mounted() {
    this.host = this.el.closest(".runs-panel"); // owns --phases-height
    this.phasesPanel = this.el.closest(".phases-panel");
    this.onDown = this.onDown.bind(this);
    this.onMove = this.onMove.bind(this);
    this.onUp = this.onUp.bind(this);
    this.el.addEventListener("mousedown", this.onDown);
  },

  destroyed() {
    document.removeEventListener("mousemove", this.onMove);
    document.removeEventListener("mouseup", this.onUp);
  },

  onDown(event) {
    event.preventDefault();
    this.startY = event.clientY;
    this.startHeight = this.phasesPanel.getBoundingClientRect().height;
    this.hostHeight = this.host.getBoundingClientRect().height;
    document.body.style.cursor = "row-resize";
    document.body.style.userSelect = "none";
    document.addEventListener("mousemove", this.onMove);
    document.addEventListener("mouseup", this.onUp);
  },

  onMove(event) {
    const dy = event.clientY - this.startY;
    const maxH = Math.max(200, this.hostHeight - 160);
    const next = Math.max(120, Math.min(maxH, this.startHeight + dy));
    this.host.style.setProperty("--phases-height", next + "px");
  },

  onUp() {
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    document.removeEventListener("mousemove", this.onMove);
    document.removeEventListener("mouseup", this.onUp);
  }
};

const StickyTimeline = {
  mounted() {
    this.scroller = this.el.closest(".node-panel");
    this.wasAtBottom = true;
  },

  beforeUpdate() {
    if (!this.scroller) return;

    const distanceFromBottom =
      this.scroller.scrollHeight - this.scroller.scrollTop - this.scroller.clientHeight;

    this.wasAtBottom = distanceFromBottom <= 40;
  },

  updated() {
    if (!this.scroller || !this.wasAtBottom) return;
    this.scroller.scrollTop = this.scroller.scrollHeight;
  }
};

const RunsListScroll = {
  mounted() {
    this.scrollCurrentIntoView();
  },
  updated() {
    this.scrollCurrentIntoView();
  },
  scrollCurrentIntoView() {
    const row = this.el.querySelector(".runs-row.is-current");
    if (!row) return;
    const containerTop = this.el.getBoundingClientRect().top;
    const rowTop = row.getBoundingClientRect().top;
    const offset = rowTop - containerTop + this.el.scrollTop;
    this.el.scrollTop = Math.max(0, offset - 8);
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").content;
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { GraphBoard, Resizer, RunsListScroll, StickyTimeline, ThemeToggle, VerticalResizer },
  params: { _csrf_token: csrfToken }
});

liveSocket.connect();
window.liveSocket = liveSocket;
