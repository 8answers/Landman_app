Future<bool> isReloadNavigation() async {
  // Non-web fallback: preserve existing restore behavior.
  return true;
}

void replaceBrowserPath(String path) {
  // No-op on non-web platforms.
}
