import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";

const nodeStates = ["pending", "running", "succeeded", "failed"];

const GraphBoard = {
  mounted() {
    this.svg = this.el.querySelector("svg");
    if (!this.svg) return;

    if (window.svgPanZoom) {
      this.panZoom = window.svgPanZoom(this.svg, {
        zoomEnabled: true,
        panEnabled: true,
        controlIconsEnabled: false,
        fit: true,
        center: true,
        minZoom: 0.2,
        maxZoom: 8,
        dblClickZoomEnabled: false
      });
    }

    this.el.addEventListener("dblclick", () => this.reset());

    this.svg.querySelectorAll("g.tractor-node[data-node-id]").forEach((node) => {
      node.addEventListener("click", (event) => {
        event.stopPropagation();
        const nodeId = node.getAttribute("data-node-id");
        this.pushEvent("select_node", { "node-id": nodeId });
      });
    });

    this.handleEvent("graph:node_state", ({ node_id, state }) => {
      this.applyState(node_id, state);
    });

    this.handleEvent("graph:selected", ({ node_id }) => {
      this.applySelected(node_id);
    });
  },

  destroyed() {
    if (this.panZoom) this.panZoom.destroy();
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
  },

  applySelected(nodeId) {
    this.svg.querySelectorAll("g.tractor-node.is-selected").forEach((node) => {
      node.classList.remove("is-selected");
    });

    const selected = this.findNode(nodeId);
    if (selected) selected.classList.add("is-selected");
  },

  findNode(nodeId) {
    if (!nodeId || !this.svg) return null;
    return this.svg.querySelector(`g.tractor-node[data-node-id="${CSS.escape(nodeId)}"]`);
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").content;
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { GraphBoard },
  params: { _csrf_token: csrfToken }
});

liveSocket.connect();
window.liveSocket = liveSocket;
