const header = document.querySelector(".site-header");
const menuToggle = document.querySelector(".menu-toggle");
const nav = document.querySelector("#site-nav");
const progress = document.querySelector(".scroll-progress");
const filters = Array.from(document.querySelectorAll(".filter-btn"));
const projectCards = Array.from(document.querySelectorAll(".project-card"));
const revealItems = Array.from(document.querySelectorAll(".reveal, .reveal-delay"));
const progressBars = Array.from(document.querySelectorAll(".progress-fill"));
const statCounters = Array.from(document.querySelectorAll("[data-count]"));
const yearNode = document.querySelector("[data-year]");
const form = document.querySelector("#contact-form");
const formStatus = document.querySelector("#form-status");

if (yearNode) {
  yearNode.textContent = new Date().getFullYear();
}

if (menuToggle && header && nav) {
  menuToggle.addEventListener("click", () => {
    const expanded = menuToggle.getAttribute("aria-expanded") === "true";
    menuToggle.setAttribute("aria-expanded", String(!expanded));
    header.classList.toggle("is-open");
  });

  nav.addEventListener("click", (event) => {
    if (event.target.matches("a")) {
      header.classList.remove("is-open");
      menuToggle.setAttribute("aria-expanded", "false");
    }
  });
}

const updateScrollProgress = () => {
  const scrollTop = window.scrollY || document.documentElement.scrollTop;
  const scrollable = document.documentElement.scrollHeight - window.innerHeight;
  const ratio = scrollable > 0 ? scrollTop / scrollable : 0;
  progress.style.transform = `scaleX(${Math.min(Math.max(ratio, 0), 1)})`;
};

updateScrollProgress();
window.addEventListener("scroll", updateScrollProgress, { passive: true });
window.addEventListener("resize", updateScrollProgress);

const animateCounter = (node) => {
  if (node.dataset.animated === "true") return;
  node.dataset.animated = "true";

  const endValue = Number(node.dataset.count || "0");
  const suffix = node.dataset.suffix || "";
  const duration = 1100;
  const start = performance.now();

  const frame = (now) => {
    const elapsed = now - start;
    const progressValue = Math.min(elapsed / duration, 1);
    const eased = 1 - Math.pow(1 - progressValue, 3);
    const value = Math.round(endValue * eased);
    const formatted = value.toString().padStart(endValue < 10 ? 2 : String(endValue).length, "0");
    node.textContent = `${formatted}${suffix}`;

    if (progressValue < 1) {
      requestAnimationFrame(frame);
    }
  };

  requestAnimationFrame(frame);
};

if (progressBars.length) {
  progressBars.forEach((bar) => {
    bar.style.width = "0%";
  });
}

const revealAll = () => {
  revealItems.forEach((item) => item.classList.add("is-visible"));
  progressBars.forEach((bar) => {
    bar.style.width = bar.dataset.width || bar.style.getPropertyValue("--target-width") || "100%";
  });
  statCounters.forEach(animateCounter);
};

if (!("IntersectionObserver" in window)) {
  revealAll();
} else {
  const revealObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;

        entry.target.classList.add("is-visible");

        const bars = entry.target.querySelectorAll?.(".progress-fill");
        bars?.forEach((bar) => {
          const width = bar.dataset.width || "0%";
          requestAnimationFrame(() => {
            bar.style.width = width;
          });
        });

        const counters = entry.target.querySelectorAll?.("[data-count]");
        counters?.forEach(animateCounter);

        revealObserver.unobserve(entry.target);
      }
    },
    { threshold: 0.15 }
  );

  revealItems.forEach((item) => revealObserver.observe(item));
}

const activateFilter = (filterValue) => {
  filters.forEach((button) => {
    const active = button.dataset.filter === filterValue;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", String(active));
  });

  projectCards.forEach((card) => {
    const match = filterValue === "all" || card.dataset.category === filterValue;
    card.hidden = !match;
  });
};

filters.forEach((button) => {
  button.addEventListener("click", () => {
    activateFilter(button.dataset.filter || "all");
  });
});

if (form && formStatus) {
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    formStatus.textContent = "تم تجهيز رسالتك بنجاح. هذه الواجهة جاهزة للربط بخدمة الإرسال لاحقًا.";
    form.reset();
  });
}
