/**
 * The brand mark: a covered-call payoff glyph. One ultramarine stroke (14% of the box, round
 * caps) rising at 45° then flat at the cap. Same path as public/favicon.svg and brand/.
 */
export function Mark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 100 100" aria-hidden="true" focusable="false">
      <path
        d="M12 69 L50 31 L88 31"
        fill="none"
        stroke="#2A3BFF"
        strokeWidth="14"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
