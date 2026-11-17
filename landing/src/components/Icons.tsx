type IconProps = {
  class?: string;
};

export function LogoMark(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <rect x="7" y="5" width="20" height="20" rx="5.5" fill="currentColor" fill-opacity=".38" />
      <rect x="4" y="9" width="20" height="20" rx="5.5" fill="currentColor" />
      <circle cx="10" cy="15" r="2.1" fill="white" />
      <path d="M7 25l5.2-5.4 3.4 3.2 3.6-4.2L23 25H7z" fill="white" />
    </svg>
  );
}

export function CheckIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M5 12.5l4.2 4.2L19 7" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function CloudCheckIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M7.5 18.5h9.25a4.25 4.25 0 0 0 .55-8.46A6.25 6.25 0 0 0 5.2 11.1 3.7 3.7 0 0 0 7.5 18.5Z"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <path d="M9.4 13.9l1.9 1.9 3.5-3.7" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function BucketIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M4.5 6.5h15M5.5 6.5l1.2 12.2a1.5 1.5 0 0 0 1.5 1.3h7.6a1.5 1.5 0 0 0 1.5-1.3L18.5 6.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
      <path d="M9 10.2v6.2M15 10.2v6.2" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />
    </svg>
  );
}

export function ShieldIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M12 3.5l7 2.6v5.2c0 4.4-2.9 7.6-7 9.2-4.1-1.6-7-4.8-7-9.2V6.1l7-2.6Z"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linejoin="round"
      />
      <path d="M8.8 11.9l2.1 2.1 4.3-4.4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export function SearchIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <circle cx="10.8" cy="10.8" r="6.2" stroke="currentColor" stroke-width="1.9" />
      <path d="M15.5 15.5L20 20" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" />
    </svg>
  );
}

export function FaceIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <circle cx="12" cy="12" r="8.4" stroke="currentColor" stroke-width="1.8" />
      <circle cx="9.2" cy="10.2" r="1" fill="currentColor" />
      <circle cx="14.8" cy="10.2" r="1" fill="currentColor" />
      <path d="M8.8 14.4c.9 1.2 2 1.8 3.2 1.8s2.3-.6 3.2-1.8" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
    </svg>
  );
}

export function LockIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect x="5.5" y="10.5" width="13" height="9.5" rx="2.4" stroke="currentColor" stroke-width="1.8" />
      <path d="M8.5 10.5V8.2a3.5 3.5 0 0 1 7 0v2.3" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />
      <circle cx="12" cy="15.2" r="1.2" fill="currentColor" />
    </svg>
  );
}

export function SparkleIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M12 3.5l1.6 4.9L18.5 10l-4.9 1.6L12 16.5l-1.6-4.9L5.5 10l4.9-1.6L12 3.5Z" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" />
      <path d="M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z" fill="currentColor" />
    </svg>
  );
}

export function GitHubIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 2.6a9.6 9.6 0 0 0-3 18.7c.5.1.7-.2.7-.5v-1.7c-2.8.6-3.4-1.2-3.4-1.2-.4-1.1-1.1-1.4-1.1-1.4-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.3 1.1 2.9.8.1-.6.3-1.1.6-1.4-2.2-.2-4.6-1.1-4.6-5 0-1.1.4-2 1-2.7-.1-.2-.4-1.3.1-2.7 0 0 .8-.3 2.7 1a9.2 9.2 0 0 1 5 0c1.9-1.3 2.7-1 2.7-1 .5 1.4.2 2.5.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.4 4.8-4.6 5 .3.3.6.9.6 1.9v2.8c0 .3.2.6.7.5A9.6 9.6 0 0 0 12 2.6Z" />
    </svg>
  );
}

export function ArrowIcon(props: IconProps) {
  return (
    <svg class={props.class} viewBox="0 0 20 20" fill="none" aria-hidden="true">
      <path d="M4 10h11M10.5 5.5L15 10l-4.5 4.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}
