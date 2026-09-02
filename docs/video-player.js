"use strict";

const video = document.getElementById("demo-video");
const status = document.getElementById("playback-status");

video.addEventListener("loadedmetadata", () => {
  status.textContent = "Ready. Press Play to begin.";
});
video.addEventListener("playing", () => {
  status.textContent = "Playing.";
});
video.addEventListener("pause", () => {
  if (!video.ended) status.textContent = "Paused. Press Play to continue.";
});
video.addEventListener("ended", () => {
  status.textContent = "Finished. Press Play to watch again.";
});
video.addEventListener("error", () => {
  status.textContent = "The video could not be loaded. Use the MP4 download link below.";
});
