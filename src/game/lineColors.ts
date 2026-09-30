/** One colour per winning line in a spin, in the order the server listed them.
 *  Twenty strong, mid-dark colours that stay readable over the white board and
 *  over photographs. Past twenty (the most a spin can pay is 29) the colours repeat
 *  with a dashed stroke, so no two lines on the board look the same. */
export const LINE_COLORS = [
  '#E5484D', '#3E63DD', '#30A46C', '#F76B15', '#8E4EC6',
  '#0D9488', '#D6409F', '#CA8A04', '#0284C7', '#65A30D',
  '#BE123C', '#4F46E5', '#0F766E', '#C2410C', '#7C3AED',
  '#059669', '#DB2777', '#1D4ED8', '#A16207', '#475569',
] as const;

export function lineColor(i: number) {
  return LINE_COLORS[i % LINE_COLORS.length];
}

export function lineDashed(i: number) {
  return i >= LINE_COLORS.length;
}
