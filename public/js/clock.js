export function start(element) {
  const tick = () => {
    element.textContent = new Date().toLocaleTimeString();
  };

  tick();
  return setInterval(tick, 1000);
}
