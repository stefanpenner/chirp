#!/usr/bin/env python3
"""
Generate the Chirp app icon — a stylized bird with sound waves.

Design: A modern, minimal bird silhouette facing right with three concentric
sound-wave arcs radiating from its beak. The bird sits on a rich gradient
background that blends the app's accent colors (blue -> purple). The bird
and waves are rendered in white/light tones for contrast and clarity.

The icon uses the macOS squircle shape implicitly (iconutil handles masking),
so we fill the full 1024x1024 canvas with the background.
"""

import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
CENTER = SIZE // 2

# App accent palette
BLUE = (102, 156, 255)
PURPLE = (140, 115, 242)
CYAN = (89, 199, 250)

# Derived colors
DARK_BG_TOP = (30, 30, 58)       # Deep navy/purple for top of gradient
DARK_BG_BOT = (20, 22, 44)       # Even darker at bottom
WHITE = (255, 255, 255)
WHITE_A = (255, 255, 255, 255)


def lerp_color(c1, c2, t):
    """Linear interpolation between two RGB(A) colors."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def draw_gradient_bg(img):
    """Draw a rich diagonal gradient background blending blue -> purple."""
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / SIZE
        # Vertical gradient from a rich blue-purple to deeper purple
        top = (45, 50, 120)
        mid = (65, 55, 140)
        bot = (35, 30, 90)
        if t < 0.5:
            color = lerp_color(top, mid, t * 2)
        else:
            color = lerp_color(mid, bot, (t - 0.5) * 2)
        draw.line([(0, y), (SIZE, y)], fill=color)

    # Add a subtle radial glow in the center-upper area (where the bird will be)
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    cx, cy = SIZE * 0.48, SIZE * 0.42
    max_r = SIZE * 0.55
    for r in range(int(max_r), 0, -2):
        t = r / max_r
        alpha = int(35 * (1 - t) ** 2)
        color = lerp_color(BLUE, PURPLE, 0.3)
        glow_draw.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=(*color, alpha),
        )
    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, glow)
    img.paste(img_rgba.convert("RGB"))


def draw_bird(draw, img):
    """
    Draw a stylized, geometric bird silhouette facing right.
    The bird is minimal and modern — think a swift/swallow in flight,
    drawn with clean bezier-like curves using polygon approximation.
    """
    # Bird body center and scale
    bx, by = SIZE * 0.42, SIZE * 0.48
    scale = SIZE * 0.0038

    # We'll draw the bird as a filled polygon.
    # The bird shape: a sleek swift/swallow silhouette facing right.
    # Coordinates are relative, scaled and translated.

    # Body + head (a streamlined teardrop shape facing right)
    # We use parametric points to define the silhouette

    def transform(pts):
        return [(bx + x * scale, by + y * scale) for x, y in pts]

    # === BIRD BODY ===
    # A sleek bird facing right. The beak points right.
    # Designed as a series of curves approximated by polygons.

    # Main body - a streamlined shape
    body_pts = [
        # Beak tip (rightmost point)
        (72, -5),
        # Upper beak curve
        (60, -12),
        # Head top
        (42, -22),
        # Crown
        (30, -28),
        # Back of head going into upper back
        (15, -30),
        # Upper back
        (-5, -28),
        # Upper wing root
        (-25, -30),
        # Upper wing tip (swept back, elegant)
        (-78, -62),
        (-82, -60),
        # Wing trailing edge comes back
        (-75, -48),
        (-55, -32),
        # Back body
        (-40, -22),
        # Tail fork upper
        (-70, -10),
        (-78, -8),
        # Tail fork center (the characteristic swallow fork)
        (-58, -2),
        # Tail fork lower
        (-78, 4),
        (-70, 6),
        # Lower back body
        (-40, 12),
        (-55, 24),
        (-75, 40),
        # Lower wing trailing edge
        (-82, 52),
        (-78, 54),
        # Lower wing tip
        (-25, 22),
        # Lower wing root
        (-5, 20),
        # Belly
        (15, 22),
        (30, 18),
        # Chin/throat
        (42, 12),
        (55, 5),
        (65, -1),
        # Back to beak
        (72, -5),
    ]

    # Draw shadow first (slight offset, dark, blurred)
    shadow_img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_img)
    shadow_offset = 4
    shadow_pts = [(x + shadow_offset, y + shadow_offset) for x, y in transform(body_pts)]
    shadow_draw.polygon(shadow_pts, fill=(0, 0, 0, 60))
    shadow_img = shadow_img.filter(ImageFilter.GaussianBlur(radius=12))
    # Composite shadow onto main image
    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, shadow_img)
    img.paste(img_rgba.convert("RGB"))

    # Draw the bird body with a gradient fill
    # Create a mask for the bird shape
    bird_mask = Image.new("L", (SIZE, SIZE), 0)
    mask_draw = ImageDraw.Draw(bird_mask)
    mask_draw.polygon(transform(body_pts), fill=255)

    # Create gradient for the bird (white to light cyan)
    bird_fill = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bird_fill_draw = ImageDraw.Draw(bird_fill)
    for y in range(SIZE):
        t = y / SIZE
        # From bright white-blue at top to white-purple at bottom
        top_color = (230, 240, 255, 245)
        bot_color = (220, 215, 250, 240)
        color = lerp_color(top_color, bot_color, t)
        bird_fill_draw.line([(0, y), (SIZE, y)], fill=color)

    # Apply mask
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(bird_fill, mask=bird_mask)

    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, result)
    img.paste(img_rgba.convert("RGB"))

    # Add a subtle eye
    eye_x = bx + 38 * scale
    eye_y = by - 16 * scale
    eye_r = 4.5 * scale
    draw.ellipse(
        [eye_x - eye_r, eye_y - eye_r, eye_x + eye_r, eye_y + eye_r],
        fill=(50, 45, 100),
    )
    # Eye highlight
    hi_r = 1.8 * scale
    hi_x = eye_x + 1.2 * scale
    hi_y = eye_y - 1.2 * scale
    draw.ellipse(
        [hi_x - hi_r, hi_y - hi_r, hi_x + hi_r, hi_y + hi_r],
        fill=(200, 210, 255),
    )


def draw_sound_waves(img):
    """
    Draw concentric sound wave arcs emanating from the bird's beak area.
    Three arcs in the app's accent colors (cyan, blue, purple) with
    decreasing opacity.
    """
    wave_img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    wave_draw = ImageDraw.Draw(wave_img)

    # Origin: near the beak tip
    bx, by = SIZE * 0.42, SIZE * 0.48
    scale = SIZE * 0.0038
    origin_x = bx + 72 * scale
    origin_y = by - 5 * scale

    waves = [
        # (radius, width, color, alpha)
        (SIZE * 0.09, SIZE * 0.018, CYAN, 200),
        (SIZE * 0.155, SIZE * 0.015, BLUE, 160),
        (SIZE * 0.22, SIZE * 0.012, PURPLE, 120),
    ]

    for radius, width, color, alpha in waves:
        # Draw arc from about -50 deg to +50 deg (facing right from beak)
        # We'll draw it as a thick arc
        arc_color = (*color, alpha)

        # Draw multiple thin arcs to simulate thickness with anti-aliasing
        steps = max(2, int(width / 1.5))
        for i in range(steps):
            offset = (i - steps / 2) * (width / steps)
            r = radius + offset
            bbox = [
                origin_x - r,
                origin_y - r,
                origin_x + r,
                origin_y + r,
            ]
            # Adjust alpha for soft edges
            edge_factor = 1.0 - abs(i - steps / 2) / (steps / 2)
            a = int(alpha * edge_factor ** 0.5)
            wave_draw.arc(
                bbox,
                start=-42,
                end=42,
                fill=(*color, a),
                width=3,
            )

    # Blur slightly for smoothness
    wave_img = wave_img.filter(ImageFilter.GaussianBlur(radius=2.5))

    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, wave_img)
    img.paste(img_rgba.convert("RGB"))


def draw_subtle_grid(img):
    """Add a very subtle geometric texture/pattern for depth."""
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Subtle vignette (darken corners)
    for r in range(SIZE, 0, -3):
        t = r / SIZE
        alpha = int(40 * t ** 3)
        draw.ellipse(
            [CENTER - r, CENTER - r, CENTER + r, CENTER + r],
            fill=(0, 0, 0, 0),
            outline=(0, 0, 0, alpha),
            width=3,
        )

    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, overlay)
    img.paste(img_rgba.convert("RGB"))


def draw_outer_ring(img):
    """Draw a subtle bright ring/border near the edges for polish."""
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Inner subtle glow ring
    margin = SIZE * 0.03
    r = SIZE / 2 - margin
    for i in range(5):
        offset = i * 1.5
        alpha = int(12 * (5 - i) / 5)
        color = lerp_color(BLUE, PURPLE, 0.5)
        draw.rounded_rectangle(
            [margin + offset, margin + offset, SIZE - margin - offset, SIZE - margin - offset],
            radius=SIZE * 0.19 - offset,
            outline=(*color, alpha),
            width=2,
        )

    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, overlay)
    img.paste(img_rgba.convert("RGB"))


def generate_icon():
    """Generate the master 1024x1024 icon."""
    img = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. Background gradient
    draw_gradient_bg(img)

    # 2. Subtle vignette
    draw_subtle_grid(img)

    # 3. Bird silhouette
    draw_bird(draw, img)

    # 4. Sound waves from beak
    draw_sound_waves(img)

    # 5. Subtle border polish
    draw_outer_ring(img)

    return img


def create_iconset(master_path, output_dir):
    """Create .iconset directory with all required sizes from master PNG."""
    iconset_dir = os.path.join(output_dir, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    # Required sizes for macOS .iconset
    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    master = Image.open(master_path)

    for filename, px in sizes:
        resized = master.resize((px, px), Image.LANCZOS)
        out_path = os.path.join(iconset_dir, filename)
        resized.save(out_path, "PNG")
        print(f"  Created {filename} ({px}x{px})")

    return iconset_dir


def main():
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    scripts_dir = os.path.join(project_root, "scripts")
    chirp_dir = os.path.join(project_root, "Sources", "Chirp")

    # Generate master icon
    print("Generating 1024x1024 master icon...")
    img = generate_icon()
    master_path = os.path.join(scripts_dir, "AppIcon_1024.png")
    img.save(master_path, "PNG")
    print(f"  Saved master: {master_path}")

    # Create iconset
    print("\nCreating .iconset with all sizes...")
    iconset_dir = create_iconset(master_path, scripts_dir)

    # Convert to .icns using iconutil
    icns_path = os.path.join(chirp_dir, "AppIcon.icns")
    print(f"\nConverting to .icns...")
    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  ERROR: iconutil failed: {result.stderr}")
        sys.exit(1)
    print(f"  Created: {icns_path}")

    # Clean up
    import shutil
    shutil.rmtree(iconset_dir)
    os.remove(master_path)
    print("\nCleaned up temporary files.")
    print("Done!")


if __name__ == "__main__":
    main()
