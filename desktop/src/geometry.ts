type Rect = { x: number; y: number; width: number; height: number };
type Cut = { start: number; end: number };
export function normalizeRect(
  a: { x: number; y: number },
  b: { x: number; y: number },
): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(a.x - b.x),
    height: Math.abs(a.y - b.y),
  };
}
export function normalizeCuts(cuts: Cut[], duration: number): Cut[] {
  return cuts
    .map((c) => ({
      start: Math.max(0, c.start),
      end: Math.min(duration, c.end),
    }))
    .filter((c) => c.end > c.start)
    .sort((a, b) => a.start - b.start)
    .reduce<Cut[]>((out, c) => {
      const last = out[out.length - 1];
      if (last && c.start <= last.end) last.end = Math.max(last.end, c.end);
      else out.push({ ...c });
      return out;
    }, []);
}

export function clampRect(r: Rect, width: number, height: number): Rect {
  const w = Math.min(Math.max(1, r.width), width),
    h = Math.min(Math.max(1, r.height), height);
  return {
    x: Math.max(0, Math.min(r.x, width - w)),
    y: Math.max(0, Math.min(r.y, height - h)),
    width: w,
    height: h,
  };
}
