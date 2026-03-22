import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { sankey } from "d3-sankey";

// Connects to data-controller="sankey-chart"
export default class extends Controller {
  static values = {
    data: Object,
    nodeWidth: { type: Number, default: 15 },
    nodePadding: { type: Number, default: 20 },
    currencySymbol: { type: String, default: "$" }
  };

  // Visual constants
  static HOVER_OPACITY = 0.4;
  static HOVER_FILTER = "saturate(1.3) brightness(1.1)";
  static EXTENT_MARGIN = 16;
  static MIN_NODE_PADDING = 4;
  static MAX_PADDING_RATIO = 0.4;
  static CORNER_RADIUS = 8;
  static DEFAULT_COLOR = "var(--color-gray-400)";
  static CSS_VAR_MAP = {
    "var(--color-success)": "#10A861",
    "var(--color-destructive)": "#EC2222",
    "var(--color-gray-400)": "#9E9E9E",
    "var(--color-gray-500)": "#737373"
  };
  static MIN_LABEL_SPACING = 28; // Minimum vertical space needed for labels (2 lines)

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.#draw());
    this.resizeObserver.observe(this.element);
    this.tooltip = null;
    this.#createTooltip();
    this.#draw();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.tooltip?.remove();
    this.tooltip = null;
  }

  #draw() {
    const { nodes = [], links = [] } = this.dataValue || {};
    if (!nodes.length || !links.length) return;

    // Hide tooltip and reset any hover states before redrawing
    this.#hideTooltip();

    d3.select(this.element).selectAll("svg").remove();

    const width = this.element.clientWidth || 600;
    const height = this.element.clientHeight || 400;

    const svg = d3.select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    const effectivePadding = this.#calculateNodePadding(nodes.length, height);
    const sankeyData = this.#generateSankeyData(nodes, links, width, height, effectivePadding);

    this.#createGradients(svg, sankeyData.links);

    const linkPaths = this.#drawLinks(svg, sankeyData.links);
    const { nodeGroups, hiddenLabels } = this.#drawNodes(svg, sankeyData.nodes, width);

    this.#attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels);
  }

  // Dynamic padding prevents padding from dominating when there are many nodes
  #calculateNodePadding(nodeCount, height) {
    const margin = this.constructor.EXTENT_MARGIN;
    const availableHeight = height - (margin * 2);
    const maxPaddingTotal = availableHeight * this.constructor.MAX_PADDING_RATIO;
    const gaps = Math.max(nodeCount - 1, 1);
    const dynamicPadding = Math.min(this.nodePaddingValue, Math.floor(maxPaddingTotal / gaps));
    return Math.max(this.constructor.MIN_NODE_PADDING, dynamicPadding);
  }

  #generateSankeyData(nodes, links, width, height, nodePadding) {
    const margin = this.constructor.EXTENT_MARGIN;
    const sankeyGenerator = sankey()
      .nodeWidth(this.nodeWidthValue)
      .nodePadding(nodePadding)
      .extent([[margin, margin], [width - margin, height - margin]]);

    return sankeyGenerator({
      nodes: nodes.map(d => ({ ...d })),
      links: links.map(d => ({ ...d })),
    });
  }

  #createGradients(svg, links) {
    const defs = svg.append("defs");

    links.forEach((link, i) => {
      const gradientId = this.#gradientId(link, i);
      const gradient = defs.append("linearGradient")
        .attr("id", gradientId)
        .attr("gradientUnits", "userSpaceOnUse")
        .attr("x1", link.source.x1)
        .attr("x2", link.target.x0);

      gradient.append("stop")
        .attr("offset", "0%")
        .attr("stop-color", this.#colorWithOpacity(link.source.color));

      gradient.append("stop")
        .attr("offset", "100%")
        .attr("stop-color", this.#colorWithOpacity(link.target.color));
    });
  }

  #gradientId(link, index) {
    return `link-gradient-${link.source.index}-${link.target.index}-${index}`;
  }

  #colorWithOpacity(nodeColor, opacity = 0.1) {
    const defaultColor = this.constructor.DEFAULT_COLOR;
    let colorStr = nodeColor || defaultColor;

    // Map CSS variables to hex values for d3 color manipulation
    colorStr = this.constructor.CSS_VAR_MAP[colorStr] || colorStr;

    // Unmapped CSS vars cannot be manipulated, return as-is
    if (colorStr.startsWith("var(--")) return colorStr;

    const d3Color = d3.color(colorStr);
    return d3Color ? d3Color.copy({ opacity }) : defaultColor;
  }

  #drawLinks(svg, links) {
    return svg.append("g")
      .attr("fill", "none")
      .selectAll("path")
      .data(links)
      .join("path")
      .attr("class", "sankey-link")
      .attr("d", d => d3.linkHorizontal()({
        source: [d.source.x1, d.y0],
        target: [d.target.x0, d.y1]
      }))
      .attr("stroke", (d, i) => `url(#${this.#gradientId(d, i)})`)
      .attr("stroke-width", d => Math.max(1, d.width))
      .style("transition", "opacity 0.3s ease");
  }

  #drawNodes(svg, nodes, width) {
    const nodeGroups = svg.append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .style("transition", "opacity 0.3s ease");

    nodeGroups.append("path")
      .attr("d", d => this.#nodePath(d))
      .attr("fill", d => d.color || this.constructor.DEFAULT_COLOR)
      .attr("stroke", d => d.color ? "none" : "var(--color-gray-500)");

    const hiddenLabels = this.#addNodeLabels(nodeGroups, width, nodes);

    return { nodeGroups, hiddenLabels };
  }

  #nodePath(node) {
    const { x0, y0, x1, y1 } = node;
    const height = y1 - y0;
    const radius = Math.max(0, Math.min(this.constructor.CORNER_RADIUS, height / 2));

    const isSourceNode = node.sourceLinks?.length > 0 && !node.targetLinks?.length;
    const isTargetNode = node.targetLinks?.length > 0 && !node.sourceLinks?.length;

    // Too small for rounded corners
    if (height < radius * 2) {
      return this.#rectPath(x0, y0, x1, y1);
    }

    if (isSourceNode) {
      return this.#roundedLeftPath(x0, y0, x1, y1, radius);
    }

    if (isTargetNode) {
      return this.#roundedRightPath(x0, y0, x1, y1, radius);
    }

    return this.#rectPath(x0, y0, x1, y1);
  }

  #rectPath(x0, y0, x1, y1) {
    return `M ${x0},${y0} L ${x1},${y0} L ${x1},${y1} L ${x0},${y1} Z`;
  }

  #roundedLeftPath(x0, y0, x1, y1, r) {
    return `M ${x0 + r},${y0}
            L ${x1},${y0}
            L ${x1},${y1}
            L ${x0 + r},${y1}
            Q ${x0},${y1} ${x0},${y1 - r}
            L ${x0},${y0 + r}
            Q ${x0},${y0} ${x0 + r},${y0} Z`;
  }

  #roundedRightPath(x0, y0, x1, y1, r) {
    return `M ${x0},${y0}
            L ${x1 - r},${y0}
            Q ${x1},${y0} ${x1},${y0 + r}
            L ${x1},${y1 - r}
            Q ${x1},${y1} ${x1 - r},${y1}
            L ${x0},${y1} Z`;
  }

  #addNodeLabels(nodeGroups, width, nodes) {
    const controller = this;
    const hiddenLabels = this.#calculateHiddenLabels(nodes);

    nodeGroups.append("text")
      .attr("x", d => d.x0 < width / 2 ? d.x1 + 6 : d.x0 - 6)
      .attr("y", d => (d.y1 + d.y0) / 2)
      .attr("dy", "-0.2em")
      .attr("text-anchor", d => d.x0 < width / 2 ? "start" : "end")
      .attr("class", "text-xs font-medium text-primary fill-current select-none")
      .style("cursor", "default")
      .style("opacity", d => hiddenLabels.has(d.index) ? 0 : 1)
      .style("transition", "opacity 0.2s ease")
      .each(function (d) {
        const textEl = d3.select(this);
        textEl.selectAll("tspan").remove();

        textEl.append("tspan").text(d.name);

        textEl.append("tspan")
          .attr("x", textEl.attr("x"))
          .attr("dy", "1.2em")
          .attr("class", "font-mono text-secondary")
          .style("font-size", "0.65rem")
          .text(controller.#formatCurrency(d.value));
      });

    return hiddenLabels;
  }

  // Calculate which labels should be hidden to prevent overlap
  #calculateHiddenLabels(nodes) {
    const hiddenLabels = new Set();
    const height = this.element.clientHeight || 400;
    const isLargeGraph = height > 600;
    const minSpacing = isLargeGraph ? this.constructor.MIN_LABEL_SPACING * 0.7 : this.constructor.MIN_LABEL_SPACING;

    // Group nodes by column (using depth which d3-sankey assigns)
    const columns = new Map();
    nodes.forEach(node => {
      const depth = node.depth;
      if (!columns.has(depth)) columns.set(depth, []);
      columns.get(depth).push(node);
    });

    // For each column, check for overlapping labels
    columns.forEach(columnNodes => {
      // Sort by vertical position
      columnNodes.sort((a, b) => ((a.y0 + a.y1) / 2) - ((b.y0 + b.y1) / 2));

      let lastVisibleY = Number.NEGATIVE_INFINITY;

      columnNodes.forEach(node => {
        const nodeY = (node.y0 + node.y1) / 2;
        const nodeHeight = node.y1 - node.y0;

        if (isLargeGraph && nodeHeight > minSpacing * 1.5) {
          lastVisibleY = nodeY;
        } else if (nodeY - lastVisibleY < minSpacing) {
          // Too close to previous visible label, hide this one
          hiddenLabels.add(node.index);
        } else {
          lastVisibleY = nodeY;
        }
      });
    });

    return hiddenLabels;
  }

  #attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels) {
    const applyHover = (targetLinks) => {
      const targetSet = new Set(targetLinks);
      const connectedNodes = new Set(targetLinks.flatMap(l => [l.source, l.target]));

      linkPaths
        .style("opacity", d => targetSet.has(d) ? 1 : this.constructor.HOVER_OPACITY)
        .style("filter", d => targetSet.has(d) ? this.constructor.HOVER_FILTER : "none");

      nodeGroups.style("opacity", d => connectedNodes.has(d) ? 1 : this.constructor.HOVER_OPACITY);

      // Show labels for connected nodes (even if normally hidden)
      nodeGroups.selectAll("text")
        .style("opacity", d => connectedNodes.has(d) ? 1 : (hiddenLabels.has(d.index) ? 0 : this.constructor.HOVER_OPACITY));
    };

    const resetHover = () => {
      linkPaths.style("opacity", 1).style("filter", "none");
      nodeGroups.style("opacity", 1);
      // Restore hidden labels to hidden state
      nodeGroups.selectAll("text")
        .style("opacity", d => hiddenLabels.has(d.index) ? 0 : 1);
    };

    linkPaths
      .on("mouseenter", (event, d) => {
        applyHover([d]);
        this.#showTooltip(event, d.value, d.percentage);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    // Hover on node rectangles (not just text)
    nodeGroups.selectAll("path")
      .style("cursor", "default")
      .on("mouseenter", (event, d) => {
        const connectedLinks = sankeyData.links.filter(l => l.source === d || l.target === d);
        applyHover(connectedLinks);
        this.#showTooltip(event, d.value, d.percentage, d.name);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    nodeGroups.selectAll("text")
      .on("mouseenter", (event, d) => {
        const connectedLinks = sankeyData.links.filter(l => l.source === d || l.target === d);
        applyHover(connectedLinks);
        this.#showTooltip(event, d.value, d.percentage, d.name);
      })
      .on("mousemove", event => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });
  }

  // Tooltip methods

  #createTooltip() {
    const dialog = this.element.closest("dialog");
    this.tooltip = d3.select(dialog || document.body)
      .append("div")
      .attr("class", "bg-gray-700 text-white text-sm p-2 rounded pointer-events-none absolute z-50 top-0")
      .style("opacity", 0)
      .style("pointer-events", "none");
  }

  #showTooltip(event, value, percentage, title = null) {
    if (!this.tooltip) this.#createTooltip();

    const content = title
      ? `${title}<br/>${this.#formatCurrency(value)} (${percentage || 0}%)`
      : `${this.#formatCurrency(value)} (${percentage || 0}%)`;

    const isInDialog = !!this.element.closest("dialog");
    const x = isInDialog ? event.clientX : event.pageX;
    const y = isInDialog ? event.clientY : event.pageY;

    this.tooltip
      .html(content)
      .style("position", isInDialog ? "fixed" : "absolute")
      .style("left", `${x + 10}px`)
      .style("top", `${y - 10}px`)
      .transition()
      .duration(100)
      .style("opacity", 1);
  }

  #updateTooltipPosition(event) {
    if (this.tooltip) {
      const isInDialog = !!this.element.closest("dialog");
      const x = isInDialog ? event.clientX : event.pageX;
      const y = isInDialog ? event.clientY : event.pageY;

      this.tooltip
        ?.style("left", `${x + 10}px`)
        .style("top", `${y - 10}px`);
    }
  }

  #hideTooltip() {
    if (this.tooltip) {
      this.tooltip
        ?.transition()
        .duration(100)
        .style("opacity", 0)
        .style("pointer-events", "none");
    }
  }

  #formatCurrency(value) {
    const formatted = Number.parseFloat(value).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
    return this.currencySymbolValue + formatted;
  }
}
