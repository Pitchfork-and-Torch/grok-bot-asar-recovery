"""Render docs/infographic.html to a PNG (exact text via Chromium)."""
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
HTML = ROOT / "docs" / "infographic.html"
DESK = Path.home() / "Desktop" / "Grok-Bot-tree-sitter-fix" / "Grok-Bot-tree-sitter-bug-fix-infographic.png"
REPO_OUT = ROOT / "docs" / "infographic.png"


def main() -> None:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(
            viewport={"width": 1200, "height": 1500},
            device_scale_factor=2,
        )
        page.goto(HTML.as_uri(), wait_until="networkidle")
        page.locator(".canvas").screenshot(path=str(REPO_OUT), type="png")
        if DESK.parent.is_dir():
            page.locator(".canvas").screenshot(path=str(DESK), type="png")
            print(f"wrote {DESK} ({DESK.stat().st_size} bytes)")
        browser.close()
    print(f"wrote {REPO_OUT} ({REPO_OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
