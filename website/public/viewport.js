export function initializeViewport() {
  const viewportPage = document.querySelector('[data-viewport-page]');
  const viewportHeader = document.querySelector('header');
  if (viewportPage && viewportHeader) {
    const controls = document.querySelector('[data-viewport-controls]');
    const measure = () => {
      const headerHeight = viewportHeader.getBoundingClientRect().height;
      const controlsHeight = controls?.getBoundingClientRect().height;
      viewportPage.style.setProperty('--header-block', headerHeight + 'px');
      if (controlsHeight !== undefined) {
        viewportPage.style.setProperty('--controls-block', controlsHeight + 'px');
      }
    };
    const observer = new ResizeObserver(measure);
    observer.observe(viewportHeader);
    if (controls) observer.observe(controls);
    measure();
  }
}
