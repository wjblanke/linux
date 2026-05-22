(function () {
  const nav = document.getElementById("nav");
  const toggle = document.getElementById("nav-toggle");
  const links = document.getElementById("nav-links");

  function onScroll() {
    nav.classList.toggle("scrolled", window.scrollY > 40);
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  if (toggle && links) {
    toggle.addEventListener("click", () => {
      const open = links.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });

    links.querySelectorAll("a").forEach((a) => {
      a.addEventListener("click", () => {
        links.classList.remove("open");
        toggle.setAttribute("aria-expanded", "false");
      });
    });
  }

  const reveals = document.querySelectorAll(".reveal");
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.1 }
  );

  reveals.forEach((el, i) => {
    el.style.transitionDelay = `${Math.min(i * 0.06, 0.36)}s`;
    observer.observe(el);
  });

  const copyBtn = document.getElementById("copy-clone");
  const cloneEl = document.getElementById("clone-url");
  if (copyBtn && cloneEl) {
    copyBtn.addEventListener("click", async () => {
      const text = cloneEl.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        copyBtn.textContent = "Copied";
        setTimeout(() => {
          copyBtn.textContent = "Copy";
        }, 2000);
      } catch {
        copyBtn.textContent = "Select & copy";
      }
    });
  }
})();
