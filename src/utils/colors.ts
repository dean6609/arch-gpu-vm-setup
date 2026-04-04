// ── Shared Tokyo Night color palette ──────────────────────────────

export const COLORS = {
  // UI elements
  border:    '#7aa2f7',
  title:     '#e0af68',
  subtitle:  '#c0caf5',
  dim:       '#565f89',
  table:     '#565f89',

  // Semantic — these match the bash fmt:: colors exactly
  success:   '#a6e3a1',
  error:     '#f38ba8',
  warning:   '#f9e2af',
  info:      '#89dceb',

  // Text states
  selected:  '#cdd6f4',
  unselected:'#6c7086',

  // Section / navigation
  section:     '#7aa2f7',
  sectionTitle:'#748cc4',
  scrollArrow: '#7aa2f7',
  arrow:     '#7aa2f7',

  // Badges (MainMenu numbered badges with background)
  badgeBg:   '#3d59a1',
  badgeBgSel:'#7aa2f7',
  badgeText: '#1a1b26',
  badgeTextSel:'#1a1b26',

  // Footer highlights
  footerBg:  '#7aa2f7',
  footerFg:  '#1a1b26',
} as const;
