// Sunburst map: same layout, ring geometry and palette as the macOS app.
'use strict';

const Sunburst = (() => {
  const TAU = Math.PI * 2;
  const MIN_ANGLE = 0.0035;
  const KIND = { FILE: 0, DIR: 1, LINK: 2, RESTRICTED: 3, HIDDEN: 4 };

  function hsb(h, s, v) {
    const f = (n) => {
      const k = (n + h * 6) % 6;
      return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
    };
    return `rgb(${Math.round(f(5) * 255)}, ${Math.round(f(3) * 255)}, ${Math.round(f(1) * 255)})`;
  }

  function color(kind, mid, depth) {
    const hue = (mid / TAU) % 1;
    const d = depth - 1;
    switch (kind) {
      case KIND.HIDDEN: return 'rgb(117, 117, 117)';
      case KIND.RESTRICTED: return hsb(hue, 0.12, 0.55);
      case KIND.FILE:
      case KIND.LINK: return hsb(hue, 0.08, Math.min(0.9, 0.72 + 0.03 * d));
      default: return hsb(hue, Math.max(0.32, 0.86 - 0.09 * d), Math.min(0.98, 0.8 + 0.035 * d));
    }
  }

  /** Flattens the nested rings from the scanner into angular segments. */
  function layout(rings, total, depth) {
    const segments = [];
    const colors = new Map();
    function build(nodes, level, start, span, parentSize, parentId) {
      if (level > depth || parentSize <= 0) return;
      let angle = start;
      const scale = span / parentSize;
      for (const node of nodes) {
        const childSpan = node.s * scale;
        if (childSpan < MIN_ANGLE) break;
        const c = color(node.k, angle + childSpan / 2, level);
        segments.push({ id: node.id, parent: parentId, kind: node.k, hasChildren: !!node.h, name: node.n, size: node.s,
          depth: level, start: angle, end: angle + childSpan, color: c });
        if (level === 1) colors.set(node.id, c);
        if (node.c) build(node.c, level + 1, angle, childSpan, node.s, node.id);
        angle += childSpan;
      }
    }
    build(rings, 1, 0, TAU, total, null);
    const parents = new Map(segments.map((s) => [s.id, s.parent]));
    return { segments, colors, depth, parents };
  }

  function geometry(width, height, depth) {
    const center = { x: width / 2, y: height / 2 };
    const outer = Math.max(40, Math.min(width, height) / 2 - 18);
    const inner = outer * 0.24;
    const weights = Array.from({ length: depth }, (_, i) => Math.pow(0.88, i));
    const unit = (outer - inner) / weights.reduce((a, b) => a + b, 0);
    const radii = [inner];
    for (const w of weights) radii.push(radii[radii.length - 1] + w * unit);
    return { center, outer, inner, radii };
  }

  /** Ring index (0 = center disc) and angle clockwise from 12 o'clock, or null outside. */
  function locate(geo, x, y) {
    const dx = x - geo.center.x;
    const dy = y - geo.center.y;
    const r = Math.hypot(dx, dy);
    let angle = Math.atan2(dy, dx) + Math.PI / 2;
    if (angle < 0) angle += TAU;
    if (r < geo.inner) return { depth: 0, angle };
    if (r > geo.outer) return null;
    let depth = geo.radii.findIndex((radius) => radius >= r);
    if (depth < 1) depth = 1;
    return { depth, angle };
  }

  function hit(model, geo, x, y) {
    const where = locate(geo, x, y);
    if (!where) return null;
    if (where.depth === 0) return { center: true };
    const segment = model.segments.find((s) => s.depth === where.depth && where.angle >= s.start && where.angle < s.end);
    return segment ? { segment } : null;
  }

  function wedge(ctx, geo, segment) {
    const r0 = geo.radii[segment.depth - 1] + 0.5;
    const r1 = geo.radii[segment.depth] - 0.5;
    const a0 = segment.start - Math.PI / 2;
    const a1 = segment.end - Math.PI / 2;
    ctx.beginPath();
    if (segment.end - segment.start >= TAU - 0.0001) {
      ctx.arc(geo.center.x, geo.center.y, r1, 0, TAU);
      ctx.moveTo(geo.center.x + r0, geo.center.y);
      ctx.arc(geo.center.x, geo.center.y, r0, 0, TAU, true);
    } else {
      ctx.arc(geo.center.x, geo.center.y, r1, a0, a1);
      ctx.arc(geo.center.x, geo.center.y, r0, a1, a0, true);
      ctx.closePath();
    }
  }

  /**
   * Draws the map. `state` supplies hovered id, ancestry test, selection and collection.
   */
  function draw(ctx, model, geo, state) {
    const { isHoveredOrInside, isSelected, isCollected, stroke } = state;
    for (const segment of model.segments) {
      wedge(ctx, geo, segment);
      ctx.fillStyle = segment.color;
      ctx.fill('evenodd');
      if (isHoveredOrInside(segment.id)) {
        ctx.fillStyle = 'rgba(255, 255, 255, 0.28)';
        ctx.fill('evenodd');
      }
      if (isCollected(segment.id)) {
        ctx.fillStyle = 'rgba(0, 0, 0, 0.38)';
        ctx.fill('evenodd');
      }
      ctx.lineWidth = 1;
      ctx.strokeStyle = stroke;
      ctx.stroke();
      if (segment.kind === KIND.HIDDEN) {
        ctx.save();
        ctx.clip('evenodd');
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.16)';
        ctx.lineWidth = 2;
        ctx.beginPath();
        for (let x = -geo.outer; x < geo.outer * 2; x += 7) {
          ctx.moveTo(geo.center.x + x, geo.center.y - geo.outer);
          ctx.lineTo(geo.center.x + x - geo.outer, geo.center.y + geo.outer);
        }
        ctx.stroke();
        ctx.restore();
      }
      if (isSelected(segment.id)) {
        wedge(ctx, geo, segment);
        ctx.strokeStyle = 'white';
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }
    const hovered = model.segments.find((s) => s.id === state.hovered);
    if (hovered) {
      wedge(ctx, geo, hovered);
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.9)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }
  }

  return { layout, geometry, hit, draw, KIND, minFraction: MIN_ANGLE / TAU };
})();
