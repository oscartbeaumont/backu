let observer: IntersectionObserver | undefined;
const reduceMotion = () =>
  typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/**
 * Adds a `.reveal` class and flips it to `.is-in` when the element first enters
 * the viewport. Motion is decorative: with reduced motion, or no
 * IntersectionObserver, the element simply stays visible.
 */
export function revealOnScroll(element: HTMLElement) {
  if (typeof window === "undefined") return;
  if (reduceMotion() || !("IntersectionObserver" in window)) return;
  element.classList.add("reveal");
  observer ??= new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-in");
        observer?.unobserve(entry.target);
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" },
  );
  observer.observe(element);
}

export function tiltOnPointer(element: HTMLElement) {
  if (typeof window === "undefined") return;
  if (reduceMotion() || !window.matchMedia("(hover: hover) and (pointer: fine)").matches) return;

  let frame = 0;
  let latest = { x: 0, y: 0 };

  const apply = () => {
    frame = 0;
    element.style.setProperty("--tilt-x", `${latest.y * -6}deg`);
    element.style.setProperty("--tilt-y", `${latest.x * 8}deg`);
  };

  const onMove = (event: PointerEvent) => {
    const rect = element.getBoundingClientRect();
    latest = {
      x: (event.clientX - rect.left) / rect.width - 0.5,
      y: (event.clientY - rect.top) / rect.height - 0.5,
    };
    if (!frame) frame = requestAnimationFrame(apply);
  };

  const reset = () => {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    element.style.setProperty("--tilt-x", "0deg");
    element.style.setProperty("--tilt-y", "0deg");
  };

  element.addEventListener("pointermove", onMove, { passive: true });
  element.addEventListener("pointerleave", reset, { passive: true });
}
