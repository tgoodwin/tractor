import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";

const nodeStates = ["pending", "running", "succeeded", "failed"];

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

    window.requestAnimationFrame(this.placeBadges);
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleKeydown);
    window.removeEventListener("resize", this.placeBadges);
    if (this.panZoom) this.panZoom.destroy();
  },

  handleKeydown(event) {
    if (event.key === "Escape") {
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
        badge.setAttribute("transform", `translate(${box.x + box.width / 2} ${box.y - 8})`);
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
    duration.classList.add("tractor-badge-duration");
    duration.setAttribute("x", "0");
    duration.setAttribute("y", "0");
    duration.setAttribute("text-anchor", "middle");

    const tokens = document.createElementNS(svgNs, "text");
    tokens.classList.add("tractor-badge-tokens");
    tokens.setAttribute("x", "0");
    tokens.setAttribute("y", "12");
    tokens.setAttribute("text-anchor", "middle");

    badge.append(duration, tokens);
    node.appendChild(badge);
    return badge;
  },

  applyBadges({ node_id: nodeId, duration, tokens, state }) {
    if (!nodeId) return;

    const payload = { node_id: nodeId, duration, tokens, state };
    this.badgePayloads.set(nodeId, payload);

    const node = this.findNode(nodeId);
    if (!node) return;

    const badge = this.ensureBadge(node);
    if (!badge) return;

    badge.querySelector(".tractor-badge-duration").textContent = duration || "";
    badge.querySelector(".tractor-badge-tokens").textContent = tokens || "";
    badge.setAttribute(
      "aria-label",
      [duration && `duration ${duration}`, tokens && `tokens ${tokens}`].filter(Boolean).join(", ")
    );

    const terminal = state === "succeeded" || state === "failed";
    badge.classList.toggle("is-visible", terminal && Boolean(duration || tokens));
    this.placeBadges();
  },

  findNode(nodeId) {
    if (!nodeId || !this.svg) return null;
    return this.svg.querySelector(`g.tractor-node[data-node-id="${CSS.escape(nodeId)}"]`);
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

const csrfToken = document.querySelector("meta[name='csrf-token']").content;
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { GraphBoard, StickyTimeline },
  params: { _csrf_token: csrfToken }
});

liveSocket.connect();
window.liveSocket = liveSocket;
