#!/usr/bin/env python3
"""
High-Performance Video Renderer for SpeechRail 90-Second Autobiography Video
(V2: High-Hook Edition with a dedicated cartoon cover).
Features:
1. Revamped Act 1 with 10-second punchy Hook visuals.
2. Perfect subtitle wrapping and safe-area padding.
3. Clean vector badges and zero tofu blocks.
4. Synchronous 90.0s master timeline.
"""

import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
import qrcode
from PIL import Image, ImageDraw, ImageFont, ImageOps

BUILD_DIR = Path(__file__).parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
AUDIO_FILE = BUILD_DIR / "master_audio_90s.wav"
TIMELINE_FILE = BUILD_DIR / "timeline.json"
SPECTRUM_FILE = BUILD_DIR / "spectrum.npy"
OUTPUT_VIDEO = BUILD_DIR / "speechrail_autobiography_90s.mp4"
COVER_ART_FILE = Path(__file__).parent / "cover_art.jpg"
SHOWCASE_TIMELINE_FILE = BUILD_DIR / "voice_showcase_timeline.json"

WIDTH = 1920
HEIGHT = 1080
FPS = 30
COVER_DURATION = 3.0
TRANSITION_DURATION = 1.2
ACT6_START = 69.2
FINAL_PAGE_START = 81.2
FINAL_PAGE_TRANSITION = 1.0
DURATION = 90.0
TOTAL_FRAMES = int(FPS * DURATION)  # 2700
ION_COVER_STRENGTH = 0.42
ION_BODY_STRENGTH = 0.30
GITHUB_URL = "https://github.com/hrygo/SpeechRail"
SHOWCASE_ACCENTS = [
    (0, 245, 212),
    (0, 180, 216),
    (255, 183, 3),
    (157, 78, 221),
    (255, 110, 180),
    (120, 220, 160),
]

# Fonts: use Hiragino Sans GB (index 0)
FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
if not Path(FONT_PATH).exists():
    FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"

try:
    font_title = ImageFont.truetype(FONT_PATH, 44, index=0)
    font_subtitle = ImageFont.truetype(FONT_PATH, 24, index=0)
    font_card_header = ImageFont.truetype(FONT_PATH, 28, index=0)
    font_card_body = ImageFont.truetype(FONT_PATH, 21, index=0)
    font_hud = ImageFont.truetype(FONT_PATH, 20, index=0)
    font_sub_zh = ImageFont.truetype(FONT_PATH, 32, index=0)
    font_badge = ImageFont.truetype(FONT_PATH, 18, index=0)
    font_badge_small = ImageFont.truetype(FONT_PATH, 16, index=0)
    font_term = ImageFont.truetype(FONT_PATH, 21, index=0)
    font_cover_brand = ImageFont.truetype(FONT_PATH, 30, index=0)
    font_cover_title = ImageFont.truetype(FONT_PATH, 76, index=0)
    font_cover_subtitle = ImageFont.truetype(FONT_PATH, 28, index=0)
    font_cover_meta = ImageFont.truetype(FONT_PATH, 18, index=0)
except Exception as e:
    print(f"Font loading error: {e}")
    sys.exit(1)

with Image.open(COVER_ART_FILE) as cover_source:
    COVER_ART = cover_source.convert("RGB")

QR_CODE = qrcode.make(GITHUB_URL).convert("RGBA").resize((300, 300), Image.Resampling.NEAREST)

with TIMELINE_FILE.open(encoding="utf-8") as f:
    timeline = json.load(f)

if SHOWCASE_TIMELINE_FILE.exists():
    with SHOWCASE_TIMELINE_FILE.open(encoding="utf-8") as f:
        showcase_timeline = json.load(f)
else:
    showcase_timeline = []

spectrum_data = np.load(str(SPECTRUM_FILE))  # (2700, 64)

# Deterministic ion field particles. Their phase, orbit and speed stay stable
# across runs while their intensity follows the extracted audio spectrum.
np.random.seed(42)
ION_PARTICLES = []
for idx in range(36):
    ION_PARTICLES.append(
        {
            "phase": np.random.uniform(0.0, 2.0 * np.pi),
            "speed": np.random.uniform(0.45, 1.2),
            "radius_x": np.random.uniform(300, 820),
            "radius_y": np.random.uniform(120, 360),
            "tilt": np.random.uniform(-0.16, 0.16),
            "size": np.random.uniform(1.5, 4.0),
            "band": idx / 35.0,
        }
    )


def draw_card(draw: ImageDraw.ImageDraw, x1, y1, x2, y2, bg_color, border_color, radius=16):
    draw.rounded_rectangle(
        [x1, y1, x2, y2], radius=radius, fill=bg_color, outline=border_color, width=2
    )


def draw_badge(
    draw: ImageDraw.ImageDraw, x, y, text, fill_col, text_col, font=font_badge, radius=6
):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    px, py = 10, 4
    draw.rounded_rectangle([x, y, x + tw + px * 2, y + th + py * 2], radius=radius, fill=fill_col)
    draw.text((x + px, y + py - 1), text, fill=text_col, font=font)
    return tw + px * 2


def draw_bullet(draw: ImageDraw.ImageDraw, x, y, color):
    r = 3.5
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw_status_dot(draw: ImageDraw.ImageDraw, x, y, color, glow_color=None):
    if glow_color:
        draw.ellipse([x - 7, y - 7, x + 7, y + 7], fill=glow_color)
    draw.ellipse([x - 4, y - 4, x + 4, y + 4], fill=color)


def draw_geo_arrow(draw: ImageDraw.ImageDraw, x, y, size=10, color=(0, 220, 255)):
    p1 = [(x, y - size), (x + size, y), (x, y + size)]
    p2 = [(x + size * 0.8, y - size), (x + size * 1.8, y), (x + size * 0.8, y + size)]
    draw.polygon(p1, fill=color)
    draw.polygon(p2, fill=color)


def add_ion_field(
    frame: Image.Image, t: float, frame_idx: int, strength: float = 1.0
) -> Image.Image:
    """Overlay an audio-reactive ion field behind the information layers."""
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    safe_idx = min(max(frame_idx, 0), len(spectrum_data) - 1)
    energy = float(np.clip(np.mean(spectrum_data[safe_idx, :48]) * 1.35, 0.15, 1.0))
    center_x = int(WIDTH * 0.70)
    center_y = int(HEIGHT * 0.47)

    ring_specs = [
        (500, 260, (0, 245, 212), 0.0),
        (680, 370, (255, 183, 3), 132.0),
    ]
    for radius_x, radius_y, color, phase in ring_specs:
        box = [
            center_x - radius_x,
            center_y - radius_y,
            center_x + radius_x,
            center_y + radius_y,
        ]
        rotation = math.degrees(t * (0.18 + energy * 0.24))
        start = (phase + rotation) % 360
        span = 72 + int(energy * 52)
        alpha = int((24 + energy * 24) * strength)
        draw.arc(box, start=start, end=start + span, fill=(*color, alpha), width=2)
        draw.arc(
            box,
            start=start + 180,
            end=start + 180 + span // 2,
            fill=(*color, max(18, alpha // 2)),
            width=1,
        )

    # Long vector rails make the field read as a routing system, not random
    # stars. They also give the cover-to-body transition a shared direction.
    vector_lines = [
        ((-80, 835), (1740, 360), (0, 245, 212)),
        ((-120, 735), (1890, 170), (255, 183, 3)),
    ]
    for (x1, y1), (x2, y2), color in vector_lines:
        draw.line(
            (x1, y1, x2, y2),
            fill=(*color, int(18 * strength)),
            width=1,
        )

    # Orbiting ions. The spectrum controls both their brightness and their
    # velocity, so the visual field visibly responds to the voice track.
    for particle in ION_PARTICLES:
        angular_speed = particle["speed"] * (0.8 + energy * 1.7)
        angle = particle["phase"] + t * angular_speed
        radius_x = particle["radius_x"] * (0.96 + 0.06 * energy)
        radius_y = particle["radius_y"] * (0.96 + 0.10 * energy)
        x = center_x + math.cos(angle) * radius_x
        y = center_y + math.sin(angle) * radius_y + particle["tilt"] * (x - center_x)

        if x < -80 or x > WIDTH + 80 or y < -80 or y > HEIGHT + 80:
            continue

        tangent_x = -math.sin(angle) * radius_x
        tangent_y = math.cos(angle) * radius_y
        tangent_norm = max(math.hypot(tangent_x, tangent_y), 1.0)
        tail_length = 6 + int(16 * energy)
        tail_x = x - tangent_x / tangent_norm * tail_length
        tail_y = y - tangent_y / tangent_norm * tail_length

        band = particle["band"]
        if band < 0.72:
            color = (0, 245, 212)
        elif band < 0.93:
            color = (255, 183, 3)
        else:
            color = (235, 78, 221)

        alpha = int((28 + energy * 56) * strength)
        width = max(1, int(particle["size"] * (0.55 + energy * 0.45)))
        draw.line((tail_x, tail_y, x, y), fill=(*color, alpha // 2), width=width)
        radius = particle["size"] * (0.7 + energy * 0.45)
        draw.ellipse(
            (x - radius * 1.6, y - radius * 1.6, x + radius * 1.6, y + radius * 1.6),
            fill=(*color, max(4, alpha // 6)),
        )
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(*color, alpha))

    return Image.alpha_composite(frame.convert("RGBA"), overlay)


def render_cover_frame(t: float, text_strength: float = 1.0) -> Image.Image:
    progress = min(max(t / COVER_DURATION, 0.0), 1.0)
    zoom = 1.0 + 0.045 * progress
    scaled_size = (int(WIDTH * zoom), int(HEIGHT * zoom))
    cover = ImageOps.fit(
        COVER_ART,
        scaled_size,
        method=Image.Resampling.LANCZOS,
        centering=(0.68, 0.5),
    )
    crop_left = (scaled_size[0] - WIDTH) // 2
    crop_top = (scaled_size[1] - HEIGHT) // 2
    frame = cover.crop((crop_left, crop_top, crop_left + WIDTH, crop_top + HEIGHT))

    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (3, 8, 18, 35))
    overlay_draw = ImageDraw.Draw(overlay)
    overlay_draw.rectangle((0, 0, WIDTH // 2 + 120, HEIGHT), fill=(2, 7, 17, 142))
    overlay_draw.rectangle((0, 0, WIDTH, 120), fill=(2, 6, 14, 100))
    scan_x = int(-220 + (WIDTH + 440) * progress)
    overlay_draw.line(
        (scan_x, 130, scan_x - 300, HEIGHT - 90),
        fill=(0, 245, 212, 80),
        width=2,
    )
    frame = Image.alpha_composite(frame.convert("RGBA"), overlay)
    frame = add_ion_field(frame, t, int(t * FPS), strength=ION_COVER_STRENGTH)

    text_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(text_layer)
    fade = min(progress / 0.22, 1.0) * min(max(text_strength, 0.0), 1.0)
    alpha = int(255 * fade)
    accent_alpha = int(220 * fade)

    draw.rectangle((120, 245, 132, 720), fill=(0, 245, 212, accent_alpha))
    draw.text(
        (160, 250),
        "SPEECHRAIL / AUTOBIOGRAPHY",
        fill=(0, 245, 212, alpha),
        font=font_cover_brand,
    )
    draw.text((160, 330), "我叫 SpeechRail", fill=(255, 255, 255, alpha), font=font_cover_title)
    draw.text(
        (164, 455),
        "生于本地，常驻你的 Mac",
        fill=(190, 220, 238, alpha),
        font=font_cover_subtitle,
    )
    draw.text(
        (164, 590),
        "一条本地语音轨道",
        fill=(225, 235, 245, alpha),
        font=font_cover_subtitle,
    )
    draw.text(
        (164, 655),
        "ASR · TTS · DIARIZATION",
        fill=(0, 245, 212, alpha),
        font=font_cover_meta,
    )
    draw.line(
        (164, 720, 780, 720),
        fill=(80, 110, 135, int(150 * fade)),
        width=2,
    )
    draw.line(
        (164, 720, 164 + int(616 * progress), 720),
        fill=(255, 183, 3, accent_alpha),
        width=4,
    )
    frame = Image.alpha_composite(frame, text_layer)
    return frame.convert("RGB")


def wrap_subtitle_smart(text, max_w=1150):
    dummy_img = Image.new("RGB", (10, 10))
    dummy_draw = ImageDraw.Draw(dummy_img)
    bbox = dummy_draw.textbbox((0, 0), text, font=font_sub_zh)
    if (bbox[2] - bbox[0]) <= max_w:
        return [text]

    puncts = ["——", "，", "；", "。 ", "、", " "]
    best_idx = -1
    best_dist = 9999
    mid = len(text) // 2
    for p in puncts:
        idx = 0
        while True:
            pos = text.find(p, idx)
            if pos == -1:
                break
            cut_pos = pos + len(p)
            dist = abs(cut_pos - mid)
            if dist < best_dist:
                best_dist = dist
                best_idx = cut_pos
            idx = pos + 1

    if best_idx != -1 and 0.25 * len(text) < best_idx < 0.75 * len(text):
        return [text[:best_idx].strip(), text[best_idx:].strip()]
    return [text[:mid].strip(), text[mid:].strip()]


def get_current_subtitle(t: float):
    for item in timeline:
        if item["start"] <= t <= item["end"]:
            return item
    return None


def get_current_showcase_voice(t: float):
    previous = None
    for item in showcase_timeline:
        if t < item["start"]:
            return previous
        if item["start"] <= t <= item["end"]:
            return item
        previous = item
    return None


def draw_hud(draw: ImageDraw.ImageDraw, t: float, frame_idx: int):
    # Top bar background
    draw.rectangle([0, 0, WIDTH, 64], fill=(13, 18, 30))

    # Left: Status indicator + Brand
    draw_status_dot(draw, 50, 32, (0, 245, 212), (0, 100, 90))
    draw.text((70, 20), "SPEECHRAIL // 官方自传", fill=(0, 245, 212), font=font_hud)

    # Center intentionally stays empty. The previous top-center copy could
    # expose internal OS/draft language; public context is shown in the scene
    # title and subtitle below the HUD instead.

    # Right: Timer and Status with 50px safe border
    time_str = f"{int(t) // 60:02d}:{int(t) % 60:02d} / 01:30"
    status_str = f"127.0.0.1:8201 [IDLE: 50MB]   {time_str}"
    bbox_rt = draw.textbbox((0, 0), status_str, font=font_hud)
    rt_w = bbox_rt[2] - bbox_rt[0]
    draw_status_dot(draw, WIDTH - 50 - rt_w - 20, 32, (80, 230, 140), (20, 80, 40))
    draw.text((WIDTH - 50 - rt_w, 20), status_str, fill=(160, 230, 180), font=font_hud)

    # Progress bar (y: 64 to 67)
    draw.rectangle([0, 64, WIDTH, 67], fill=(25, 33, 50))
    prog_w = int(WIDTH * (frame_idx / TOTAL_FRAMES))
    prog_ratio = frame_idx / TOTAL_FRAMES
    r = int(0 + 245 * prog_ratio)
    g = int(220 - 90 * prog_ratio)
    b = int(255 - 223 * prog_ratio)
    draw.rectangle([0, 64, prog_w, 67], fill=(r, g, b))


def draw_act_content(draw: ImageDraw.ImageDraw, t: float, frame_idx: int):
    # Scene 1: 0.0 - 12.8s (🔥 High-Hook!)
    if t < 12.8:
        title = "停一下。让声音与隐私回到本地"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 105),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "此刻你听到的每一个字，都来自 Apple Silicon 上 SpeechRail 的本地实时合成"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 168),
            sub,
            fill=(0, 245, 212),
            font=font_subtitle,
        )

        # Left Card: Pain Points
        draw_card(draw, 120, 225, 920, 775, (26, 16, 20), (220, 60, 80))
        draw_badge(draw, 160, 255, "云端妥协", (100, 25, 35), (255, 120, 140))
        draw.text((270, 255), "云端外呼与本地内存之痛", fill=(255, 100, 120), font=font_card_header)
        cloud_points = [
            ("隐私离开本机", "音频离开本机，带来商业机密与个人隐私风险"),
            ("网络延迟抖动", "公网往返延迟，实时交互体验容易受网络影响"),
            ("持续使用成本", "按音频分钟或 Token 计费，高频使用成本逐步累加"),
            ("重复加载模型", "各应用各自加载模型，内存占用容易叠加，影响系统响应"),
        ]
        cy = 325
        for h, d in cloud_points:
            draw_bullet(draw, 170, cy + 13, (255, 90, 110))
            draw.text((190, cy), h, fill=(255, 190, 200), font=font_card_header)
            draw.text((190, cy + 40), d, fill=(190, 190, 205), font=font_card_body)
            cy += 105

        # Right Card: The SpeechRail Solution
        draw_card(draw, 1000, 225, 1800, 775, (16, 26, 32), (0, 245, 212))
        draw_badge(draw, 1040, 255, "底层破局", (0, 75, 75), (0, 255, 220))
        draw.text(
            (1150, 255), "SpeechRail 生产级本地底座", fill=(0, 245, 212), font=font_card_header
        )
        sol_points = [
            ("本地处理", "音频在本机内存中处理，数据不必离开你的 Mac"),
            ("减少重复占用", "独立进程统一提供服务，多个应用共享同一套语音能力"),
            ("一次安装，多应用共享", "一次配置，多个 Agent 与客户端按需接入"),
            ("低延迟流式", "结合 Apple MLX 统一内存加速，提供连续的流式响应"),
        ]
        ly = 325
        for h, d in sol_points:
            draw_bullet(draw, 1050, ly + 13, (0, 245, 212))
            draw.text((1070, ly), h, fill=(220, 255, 245), font=font_card_header)
            draw.text((1070, ly + 40), d, fill=(190, 215, 225), font=font_card_body)
            ly += 105

    # Scene 2: 12.8 - 27.2s
    elif t < 27.2:
        title = "SpeechRail 独立本地语音基础设施"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 105),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "不是另一个聊天应用，而是运行在 macOS 底层的共享语音服务"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 168),
            sub,
            fill=(0, 220, 255),
            font=font_subtitle,
        )

        cards = [
            (
                120,
                225,
                920,
                485,
                "开放标准",
                "兼容 OpenAI 接入方式",
                [
                    "完整实现 whisper-1、tts-1 与 /v1/realtime 双工流式契约",
                    '客户端改一行 base_url="http://127.0.0.1:8201/v1" 即可接入',
                    "生态级兼容：OpenAI SDK、LiveKit、Sona、Open-WebUI、OpenClaw",
                ],
                (0, 180, 216),
            ),
            (
                1000,
                225,
                1800,
                485,
                "隐私安全",
                "本地处理 · 数据默认留在本机",
                [
                    "默认绑定 127.0.0.1 本地回环接口，减少网络暴露范围",
                    "音频通过内存管道流转，避免中间切片落盘",
                    "本地模型可在断网状态运行，减少对公网链路的依赖",
                ],
                (0, 245, 212),
            ),
            (
                120,
                520,
                920,
                780,
                "极速响应",
                "本地运行 · 少受网络影响",
                [
                    "基于 Apple MLX 与 Metal 硬件深度调优，直接调度统一内存",
                    "流式响应不依赖公网往返，减少网络抖动影响",
                    "三档动态硬件匹配 (Quality / Balanced / Light) 自适应 Apple Silicon",
                ],
                (255, 183, 3),
            ),
            (
                1000,
                520,
                1800,
                780,
                "全机共享",
                "一个服务 · 多个应用共享",
                [
                    "作为 macOS LaunchAgent 后台守护，一个端口统一接入",
                    "多个桌面软件与 Agent 共同复用同一套语音服务",
                    "减少重复加载，降低不同工具各自占用内存的压力",
                ],
                (157, 78, 221),
            ),
        ]
        for x1, y1, x2, y2, tag, head, bullets, color in cards:
            draw_card(draw, x1, y1, x2, y2, (16, 22, 34), color)
            draw_badge(draw, x1 + 35, y1 + 28, tag, (30, 40, 60), color)
            draw.text((x1 + 145, y1 + 28), head, fill=color, font=font_card_header)
            by = y1 + 82
            for b in bullets:
                draw_bullet(draw, x1 + 45, by + 12, color)
                draw.text((x1 + 65, by), b, fill=(215, 225, 240), font=font_card_body)
                by += 52

    # Scene 3: 27.2 - 41.8s
    elif t < 41.8:
        title = "网关与模型分开运行 · 空闲自动释放"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 105),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "网关保持稳定，模型按需使用内存"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 168),
            sub,
            fill=(0, 245, 212),
            font=font_subtitle,
        )

        # Left Node: Gateway
        draw_card(draw, 120, 235, 780, 560, (16, 24, 38), (0, 180, 216))
        draw_badge(draw, 160, 265, "网关节点", (0, 80, 120), (0, 245, 212))
        draw.text(
            (270, 265), "HTTP 网关 (FastAPI 组合根)", fill=(0, 230, 255), font=font_card_header
        )
        gw_points = [
            "轻量常驻守护进程，待机约占用 50 MB 内存",
            "统一入口负责请求路由与鉴权",
            "Resource Governor：统一管理并发请求",
            "生命周期管理：Worker 异常时自动恢复",
        ]
        gy = 330
        for p in gw_points:
            draw_bullet(draw, 170, gy + 13, (0, 220, 255))
            draw.text((190, gy), p, fill=(215, 230, 245), font=font_card_body)
            gy += 50

        # Middle Node: IPC Barrier
        draw_card(draw, 825, 305, 1095, 490, (26, 20, 38), (157, 78, 221))
        draw_badge(draw, 880, 325, "物理隔离屏障", (80, 40, 120), (220, 160, 255))
        draw.text((885, 375), "高效 IPC 管道", fill=(255, 255, 255), font=font_card_header)
        draw.text((860, 425), "模型异常，网关继续工作", fill=(0, 245, 212), font=font_hud)

        # Geometric arrows
        draw_geo_arrow(draw, 792, 395, size=10, color=(0, 220, 255))
        draw_geo_arrow(draw, 1108, 395, size=10, color=(157, 78, 221))

        # Right Node: MLX Worker
        draw_card(draw, 1140, 235, 1800, 560, (26, 18, 30), (255, 110, 180))
        draw_badge(draw, 1180, 265, "重型计算", (100, 30, 70), (255, 130, 190))
        draw.text(
            (1290, 265), "独立推理 Worker (Apple MLX)", fill=(255, 130, 190), font=font_card_header
        )
        wk_points = [
            "独立进程专门执行模型推理",
            "Qwen3-ASR / TTS / Diarization 硬件加速并行流水线",
            "异常隔离：Worker 出错时不拖垮主网关",
            "音频通过内存管道高速流转，避免中间切片落盘",
        ]
        wy = 330
        for p in wk_points:
            draw_bullet(draw, 1190, wy + 13, (255, 110, 180))
            draw.text((1210, wy), p, fill=(245, 220, 230), font=font_card_body)
            wy += 50

        # Bottom Eviction Card
        draw_card(draw, 120, 595, 1800, 765, (14, 28, 28), (0, 245, 212))
        draw_badge(draw, 160, 620, "自适应显存治理", (0, 70, 65), (0, 255, 220))
        draw.text(
            (325, 620),
            "自动内存管理 (Idle Eviction)",
            fill=(0, 245, 212),
            font=font_card_header,
        )
        draw_bullet(draw, 170, 680, (0, 245, 212))
        draw.text(
            (190, 668),
            "推理完成后开始计时；长时间无请求时，模型自动释放内存",
            fill=(210, 240, 235),
            font=font_card_body,
        )
        draw_bullet(draw, 170, 722, (255, 200, 80))
        draw.text(
            (190, 710),
            (
                "常驻待机约 50 MB，减少对 8GB / 16GB Mac 日常工作的影响"
            ),
            fill=(255, 220, 120),
            font=font_card_body,
        )

    # Scene 4: 41.8 - 56.6s
    elif t < 56.6:
        title = "实时转写 · 自动区分不同讲话人"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 105),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "支持多人对话转写 · 输出匿名讲话人标签"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 168),
            sub,
            fill=(255, 183, 3),
            font=font_subtitle,
        )

        # Left Waterfall Meeting Simulation
        draw_card(draw, 120, 225, 1140, 780, (16, 20, 32), (0, 180, 216))
        draw_badge(draw, 160, 250, "实测会话流", (0, 60, 90), (0, 220, 255))
        draw.text(
            (280, 250),
            "多人会议转写示例",
            fill=(0, 220, 255),
            font=font_card_header,
        )

        # Bubble 1 (Speaker 0)
        draw_card(draw, 160, 305, 1080, 415, (20, 35, 60), (0, 160, 255))
        draw_badge(
            draw,
            185,
            320,
            "SPEAKER 0 · 00:01.2",
            (0, 70, 120),
            (160, 220, 255),
            font=font_badge_small,
        )
        draw.text(
            (185, 360),
            "“我们今天需要把语音服务尽量留在本地，减少会议记录离开公司网的风险。”",
            fill=(255, 255, 255),
            font=font_card_body,
        )

        # Bubble 2 (Speaker 1)
        draw_card(draw, 160, 440, 1080, 550, (45, 28, 18), (255, 140, 40))
        draw_badge(
            draw,
            185,
            455,
            "SPEAKER 1 · 00:04.8",
            (100, 50, 20),
            (255, 190, 120),
            font=font_badge_small,
        )
        draw.text(
            (185, 495),
            "“SpeechRail 能把两人的发言分开，录音更容易整理。”",
            fill=(255, 255, 255),
            font=font_card_body,
        )

        # Bubble 3 (Speaker 0)
        draw_card(draw, 160, 575, 1080, 685, (20, 35, 60), (0, 160, 255))
        draw_badge(
            draw,
            185,
            590,
            "SPEAKER 0 · 00:09.4",
            (0, 70, 120),
            (160, 220, 255),
            font=font_badge_small,
        )
        draw.text(
            (185, 630),
            "“还支持 /v1/realtime 流式更新讲话人归属。”",
            fill=(255, 255, 255),
            font=font_card_body,
        )

        draw_bullet(draw, 170, 725, (0, 245, 212))
        draw.text(
            (190, 715),
            "输出 session-scoped 匿名标签，不把实名身份带进服务",
            fill=(0, 245, 212),
            font=font_hud,
        )

        # Right Specification Card
        draw_card(draw, 1180, 225, 1800, 780, (22, 26, 38), (255, 183, 3))
        draw_badge(draw, 1220, 250, "技术指标", (80, 60, 20), (255, 200, 50))
        draw.text((1330, 250), "架构与契约优势", fill=(255, 200, 50), font=font_card_header)
        spec_points = [
            ("Sortformer 多人分离", "持续更新声学活动与讲话人归属"),
            ("CAM++ 深度声纹表征", "提取讲话人特征，适配多人对话场景"),
            ("双模式全面覆盖", "支持离线长音频 diarized_json 与低延迟流式 WebSocket"),
            ("工业级屏障保障", "先固定转写正文，再更新讲话人归属，减少状态冲突"),
        ]
        sy = 325
        for title, desc in spec_points:
            draw_bullet(draw, 1230, sy + 14, (255, 183, 3))
            draw.text((1250, sy), title, fill=(255, 220, 120), font=font_card_header)
            draw.text((1250, sy + 42), desc, fill=(200, 210, 225), font=font_card_body)
            sy += 105

    # Scene 5: 56.6 - 69.2s (Showcase Voices)
    elif t < ACT6_START:
        title = "多种本地音色 · 自然切换"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 105),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "本地实时合成 · 多种音色 · 跨语言切换"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 168),
            sub,
            fill=(255, 110, 180),
            font=font_subtitle,
        )

        is_uncle = (t < 58.8) or (t >= 64.2)
        is_vivian = 58.8 <= t < 61.5
        is_ryan = 61.5 <= t < 64.2

        # 3 Spotlight Cards — equal width 520px, 30px gap, centered in 1680px safe area
        card_w = 520
        gap = 30
        total_w = card_w * 3 + gap * 2  # 1620
        card_x0 = (WIDTH - total_w) // 2  # 150
        card_y0 = 225
        card_y1 = 565
        card_pad = 30  # inner padding

        # Card 1: uncle_fu
        c1_x1 = card_x0
        c1_x2 = c1_x1 + card_w
        u_border = (0, 245, 212) if is_uncle else (50, 65, 85)
        u_bg = (20, 36, 48) if is_uncle else (14, 18, 26)
        draw_card(draw, c1_x1, card_y0, c1_x2, card_y1, u_bg, u_border)
        draw_badge(
            draw,
            c1_x1 + card_pad,
            card_y0 + 30,
            "LIVE AUDIO" if is_uncle else "SPEAKER",
            (0, 80, 80) if is_uncle else (30, 40, 55),
            u_border,
        )
        draw.text(
            (c1_x1 + card_pad + 130, card_y0 + 30), "uncle_fu", fill=u_border, font=font_card_header
        )
        draw.text(
            (c1_x1 + card_pad, card_y0 + 80),
            "成熟稳重 · 醇厚中文男声",
            fill=(220, 230, 245),
            font=font_subtitle,
        )
        draw.text(
            (c1_x1 + card_pad, card_y0 + 130),
            "· 音色低沉醇厚，表达从容平稳\n· 适配叙事、播客与严肃助手\n· 原生 24kHz 采样，保真共鸣",
            fill=(180, 195, 215),
            font=font_card_body,
        )

        # Card 2: vivian
        c2_x1 = c1_x2 + gap
        c2_x2 = c2_x1 + card_w
        v_border = (255, 90, 180) if is_vivian else (50, 65, 85)
        v_bg = (40, 18, 32) if is_vivian else (14, 18, 26)
        draw_card(draw, c2_x1, card_y0, c2_x2, card_y1, v_bg, v_border)
        draw_badge(
            draw,
            c2_x1 + card_pad,
            card_y0 + 30,
            "LIVE AUDIO" if is_vivian else "SPEAKER",
            (80, 20, 50) if is_vivian else (30, 40, 55),
            v_border,
        )
        draw.text(
            (c2_x1 + card_pad + 130, card_y0 + 30), "vivian", fill=v_border, font=font_card_header
        )
        draw.text(
            (c2_x1 + card_pad, card_y0 + 80),
            "明亮清脆 · 年轻中文女声",
            fill=(255, 200, 225),
            font=font_subtitle,
        )
        draw.text(
            (c2_x1 + card_pad, card_y0 + 130),
            "· 语气轻快自然，锋利质感\n· 极佳穿透力，适合语音交互\n· 细腻气息与情绪起伏掌控",
            fill=(215, 185, 200),
            font=font_card_body,
        )

        # Card 3: ryan
        c3_x1 = c2_x2 + gap
        c3_x2 = c3_x1 + card_w
        r_border = (255, 183, 3) if is_ryan else (50, 65, 85)
        r_bg = (40, 32, 14) if is_ryan else (14, 18, 26)
        draw_card(draw, c3_x1, card_y0, c3_x2, card_y1, r_bg, r_border)
        draw_badge(
            draw,
            c3_x1 + card_pad,
            card_y0 + 30,
            "LIVE AUDIO" if is_ryan else "SPEAKER",
            (80, 55, 10) if is_ryan else (30, 40, 55),
            r_border,
        )
        draw.text(
            (c3_x1 + card_pad + 130, card_y0 + 30), "ryan", fill=r_border, font=font_card_header
        )
        draw.text(
            (c3_x1 + card_pad, card_y0 + 80),
            "动感原生 · 节奏英语男声",
            fill=(255, 230, 180),
            font=font_subtitle,
        )
        draw.text(
            (c3_x1 + card_pad, card_y0 + 130),
            "· 活力推动力 Native English\n· 地道情绪重音与语调流转\n· 跨语言自然切换，多语种",
            fill=(215, 205, 180),
            font=font_card_body,
        )

        # Bottom 9-Voice Grid Card — evenly distribute badges
        grid_x1 = card_x0
        grid_x2 = c3_x2
        draw_card(draw, grid_x1, 600, grid_x2, 770, (18, 24, 36), (157, 78, 221))
        draw_badge(draw, grid_x1 + card_pad, 618, "音色库矩阵", (60, 30, 90), (220, 160, 255))
        draw.text(
            (grid_x1 + card_pad + 105, 620),
            "9 种内置音色，可由 Apple Silicon 在本地实时合成：",
            fill=(210, 180, 255),
            font=font_card_body,
        )
        voices_all = [
            ("serena", "温柔中文女声"),
            ("uncle_fu", "醇厚中文男声"),
            ("vivian", "明亮中文女声"),
            ("dylan", "北京青年男声"),
            ("eric", "成都活力男声"),
            ("ryan", "动感英语男声"),
            ("aiden", "阳光美式男声"),
            ("ono_anna", "轻快日语女声"),
            ("sohee", "温暖韩语女声"),
        ]
        col_w = (grid_x2 - grid_x1 - card_pad * 2) // 3  # ~520px per column
        for idx, (vid, vdesc) in enumerate(voices_all):
            col = idx % 3
            row = idx // 3
            vx = grid_x1 + card_pad + col * col_w
            vy = 670 + row * 34
            draw_badge(
                draw,
                vx,
                vy,
                f"{vid} · {vdesc}",
                (28, 36, 52),
                (235, 240, 255),
                font=font_badge_small,
                radius=4,
            )

    # Scene 6: 69.2 - 90.0s (Finale)
    else:
        title = "自由的轨道 · 把声音与隐私还给自己"
        bbox_t = draw.textbbox((0, 0), title, font=font_title)
        draw.text(
            ((WIDTH - (bbox_t[2] - bbox_t[0])) // 2, 95),
            title,
            fill=(255, 255, 255),
            font=font_title,
        )

        sub = "面向 Apple Silicon Mac 的本地共享语音服务"
        bbox_s = draw.textbbox((0, 0), sub, font=font_subtitle)
        draw.text(
            ((WIDTH - (bbox_s[2] - bbox_s[0])) // 2, 155),
            sub,
            fill=(0, 245, 212),
            font=font_subtitle,
        )

        # Left Terminal Window
        draw_card(draw, 120, 215, 1050, 780, (14, 18, 26), (60, 80, 110))
        draw.rectangle([120, 215, 1050, 265], fill=(24, 30, 44))
        draw.ellipse([145, 235, 157, 247], fill=(255, 95, 87))
        draw.ellipse([167, 235, 179, 247], fill=(254, 188, 46))
        draw.ellipse([189, 235, 201, 247], fill=(40, 200, 64))
        draw.text(
            (225, 232),
            "Terminal — SpeechRail Zero-Setup Bootstrap",
            fill=(170, 185, 205),
            font=font_hud,
        )

        term_lines = [
            ("# 1. 克隆开源仓库并一键极速安装", (100, 130, 160)),
            ("$ git clone https://github.com/hrygo/SpeechRail.git", (255, 255, 255)),
            ("$ cd SpeechRail", (255, 255, 255)),
            ("$ ./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh", (0, 245, 212)),
            ("", (0, 0, 0)),
            (">> Apple Silicon M-Series Chip Detected: OK", (120, 220, 160)),
            (">> Isolated Python 3.12 Runtime Prepared: OK", (120, 220, 160)),
            (">> Model Weights Verified (Quality Profile): OK", (120, 220, 160)),
            (">> macOS LaunchAgent Registered (com.speechrail): OK", (120, 220, 160)),
            ("", (0, 0, 0)),
            ("● [SpeechRail 1.8.1] Listening on http://127.0.0.1:8201", (0, 255, 200)),
            ("● [Health Probe] readyz = 200 OK | ASR, TTS, Diarization READY!", (0, 255, 200)),
        ]
        ty = 285
        for line, col in term_lines:
            if line:
                draw.text((150, ty), line, fill=col, font=font_term)
            ty += 38

        # Right Summary & Manifesto
        draw_card(draw, 1100, 215, 1800, 780, (18, 22, 34), (0, 245, 212))
        draw_badge(draw, 1150, 250, "核心承诺", (0, 80, 80), (0, 245, 212))
        draw.text((1260, 250), "SpeechRail 承诺与信仰", fill=(0, 245, 212), font=font_card_header)

        manifesto = [
            ("本地处理", "数据默认留在你的 Mac，具体行为以部署配置为准"),
            ("一次配置，多应用共享", "多个应用与 Agent 按需接入同一套语音服务"),
            ("网关与模型分开运行", "待机约 50MB，空闲时自动释放模型资源"),
            ("兼容 OpenAI 接入方式", "为已有 AI 工具提供熟悉的接入路径"),
        ]
        my = 325
        for h, d in manifesto:
            draw_bullet(draw, 1160, my + 14, (0, 245, 212))
            draw.text((1180, my), h, fill=(255, 255, 255), font=font_card_header)
            draw.text((1180, my + 42), d, fill=(185, 205, 225), font=font_card_body)
            my += 95

        draw.rectangle([1150, 715, 1750, 755], fill=(0, 75, 95))
        draw.text(
            (1180, 722),
            "很高兴与你同在 · 开源地址: github.com/hrygo/SpeechRail",
            fill=(0, 255, 220),
            font=font_hud,
        )


def render_final_page(t: float) -> Image.Image:
    """Render a quiet end card for the post-narration tail of the video."""
    progress = min(max((t - FINAL_PAGE_START) / (DURATION - FINAL_PAGE_START), 0.0), 1.0)
    img = Image.new("RGBA", (WIDTH, HEIGHT), (7, 13, 25, 255))
    draw = ImageDraw.Draw(img)

    # Keep the end card calmer than the cover: one rail, one moving signal,
    # and a high-contrast QR code are enough to hold the final nine seconds.
    for gx in range(0, WIDTH, 80):
        draw.line((gx, 70, gx, HEIGHT - 70), fill=(18, 28, 45, 120), width=1)
    for gy in range(70, HEIGHT - 70, 80):
        draw.line((0, gy, WIDTH, gy), fill=(18, 28, 45, 120), width=1)

    # Two aligned content columns: the live voice readout and voice matrix on
    # the left, with the repository QR card on the right. The lower band is a
    # single, deliberate CTA instead of another competing information card.
    left_panel = (120, 180, 1240, 690)
    draw.rounded_rectangle(
        left_panel,
        radius=22,
        fill=(12, 20, 32, 245),
        outline=(0, 125, 150, 150),
        width=2,
    )

    draw.text(
        (120, 84),
        "SPEECHRAIL / LOCAL VOICE RAIL",
        fill=(0, 245, 212),
        font=font_cover_brand,
    )
    draw.text(
        (1450, 92),
        "OPEN SOURCE · LOCAL FIRST",
        fill=(150, 180, 205),
        font=font_hud,
    )

    active_voice = get_current_showcase_voice(t)
    active_index = next(
        (index for index, item in enumerate(showcase_timeline) if item is active_voice),
        -1,
    )
    active_color = (
        SHOWCASE_ACCENTS[active_index % len(SHOWCASE_ACCENTS)]
        if active_index >= 0
        else (0, 245, 212)
    )

    # Main readout column.
    draw.text((166, 220), "VOICE SHOWTIME", fill=(0, 245, 212), font=font_badge)
    draw.line((166, 258, 710, 258), fill=(0, 105, 130, 160), width=1)
    if active_voice:
        draw.text(
            (166, 292),
            "正文未登场的 6 种本地音色",
            fill=(175, 205, 222),
            font=font_card_header,
        )
        draw.text(
            (166, 346),
            active_voice["voice"],
            fill=active_color,
            font=font_cover_title,
        )
        draw.text(
            (168, 452),
            active_voice["description"],
            fill=(190, 215, 232),
            font=font_card_header,
        )
        showcase_caption = active_voice.get("caption", active_voice["text"])
        draw.text(
            (168, 493),
            f"“{showcase_caption}”",
            fill=(145, 175, 198),
            font=font_badge,
        )
        page_badge = f"LIVE VOICE  {active_index + 1:02d} / {len(showcase_timeline):02d}"
        page_badge_fill = (18, 28, 42)
        page_badge_text = active_color
    else:
        draw.text(
            (166, 292),
            "六组本地音色，全部完成播报",
            fill=(175, 205, 222),
            font=font_card_header,
        )
        draw.text(
            (166, 350),
            "把声音还给本地",
            fill=(0, 245, 212),
            font=font_cover_title,
        )
        draw.text(
            (168, 452),
            "SpeechRail · ASR / TTS / DIARIZATION",
            fill=(190, 215, 232),
            font=font_subtitle,
        )
        draw.text(
            (168, 493),
            "一条本地语音轨道，开放给每一个 Agent 与应用",
            fill=(145, 175, 198),
            font=font_badge,
        )
        page_badge = "SHOWTIME COMPLETE"
        page_badge_fill = (0, 75, 85)
        page_badge_text = (0, 255, 220)

    draw_badge(draw, 166, 545, page_badge, page_badge_fill, page_badge_text)

    # The matrix makes the six unused voices legible as a designed product
    # surface. Only the currently speaking slot receives a strong outline.
    matrix_x, matrix_y = 790, 220
    draw.text((matrix_x, matrix_y), "VOICE INDEX", fill=(0, 245, 212), font=font_badge)
    draw.text(
        (matrix_x + 220, matrix_y),
        "6 CHANNELS",
        fill=(120, 155, 178),
        font=font_badge_small,
    )
    draw.line((matrix_x, matrix_y + 38, 1178, matrix_y + 38), fill=(0, 105, 130, 160), width=1)
    if showcase_timeline:
        slot_w, slot_h = 122, 60
        col_gap, row_gap = 12, 22
        for index, item in enumerate(showcase_timeline):
            row, col = divmod(index, 3)
            slot_x = matrix_x + col * (slot_w + col_gap)
            slot_y = matrix_y + 82 + row * (slot_h + row_gap)
            slot_color = SHOWCASE_ACCENTS[index % len(SHOWCASE_ACCENTS)]
            is_active = item is active_voice
            draw.rounded_rectangle(
                (slot_x, slot_y, slot_x + slot_w, slot_y + slot_h),
                radius=8,
                fill=(18, 28, 42, 255) if is_active else (10, 19, 31, 220),
                outline=(*slot_color, 220 if is_active else 80),
                width=2 if is_active else 1,
            )
            draw.text(
                (slot_x + 12, slot_y + 9),
                f"{index + 1:02d}",
                fill=(135, 165, 185),
                font=font_badge_small,
            )
            draw.text(
                (slot_x + 12, slot_y + 29),
                item["voice"],
                fill=slot_color,
                font=font_badge_small,
            )
            if is_active:
                draw.text(
                    (slot_x + 82, slot_y + 10),
                    "NOW",
                    fill=slot_color,
                    font=font_badge_small,
                )

    # A restrained local waveform gives the active card motion without turning
    # the page into another particle-heavy scene.
    signal_x, signal_y, signal_w = 790, 535, 388
    draw.text(
        (signal_x, signal_y - 27), "LOCAL SIGNAL", fill=(120, 155, 178), font=font_badge_small
    )
    signal_points = []
    signal_phase = t * 7.0
    for sample in range(65):
        sx = signal_x + sample * signal_w / 64
        envelope = 0.35 + 0.65 * abs(math.sin(signal_phase * 0.35 + sample * 0.11))
        sy = signal_y + math.sin(signal_phase + sample * 0.42) * 15 * envelope
        signal_points.append((sx, sy))
    draw.line(signal_points, fill=(*active_color, 185), width=2)
    draw.line(
        (signal_x, signal_y + 24, signal_x + signal_w, signal_y + 24),
        fill=(0, 100, 125, 120),
        width=1,
    )

    # Shared rail under both columns; it provides a single compositional axis.
    rail_y = 714
    draw.line((120, rail_y, 1740, rail_y), fill=(0, 120, 150, 150), width=2)
    draw.line((120, rail_y + 10, 1740, rail_y + 10), fill=(255, 183, 3, 80), width=1)
    pulse_x = int(180 + 1500 * ((progress * 1.8) % 1.0))
    draw.ellipse((pulse_x - 9, rail_y - 9, pulse_x + 9, rail_y + 9), fill=(0, 245, 212, 220))
    draw.ellipse((pulse_x - 22, rail_y - 22, pulse_x + 22, rail_y + 22), fill=(0, 180, 216, 40))

    draw.text(
        (120, 770),
        "OPEN SOURCE / LOCAL FIRST",
        fill=(0, 245, 212),
        font=font_badge,
    )
    draw.text(
        (120, 805),
        "github.com/hrygo/SpeechRail",
        fill=(255, 255, 255),
        font=font_title,
    )
    draw.text(
        (122, 870),
        "扫描二维码，了解本地部署与完整示例",
        fill=(160, 190, 212),
        font=font_subtitle,
    )

    qr_card_x1, qr_card_y1 = 1330, 180
    qr_card_x2, qr_card_y2 = 1740, 690
    qr_center_x = (qr_card_x1 + qr_card_x2) // 2
    qr_x = qr_center_x - QR_CODE.width // 2
    qr_y = qr_card_y1 + 66
    qr_card = (qr_card_x1, qr_card_y1, qr_card_x2, qr_card_y2)
    draw.rounded_rectangle(
        qr_card, radius=22, fill=(15, 24, 38, 255), outline=(0, 245, 212, 220), width=2
    )
    qr_heading = "SCAN TO OPEN"
    qr_heading_box = draw.textbbox((0, 0), qr_heading, font=font_badge)
    draw.text(
        (qr_center_x - (qr_heading_box[2] - qr_heading_box[0]) // 2, qr_card_y1 + 24),
        qr_heading,
        fill=(0, 245, 212),
        font=font_badge,
    )
    qr_frame = (qr_x - 14, qr_y - 14, qr_x + QR_CODE.width + 14, qr_y + QR_CODE.height + 14)
    draw.rounded_rectangle(qr_frame, radius=10, outline=(70, 105, 125, 150), width=1)
    img.alpha_composite(QR_CODE, (qr_x, qr_y))
    draw = ImageDraw.Draw(img)
    qr_label = "github.com/hrygo/SpeechRail"
    qr_label_box = draw.textbbox((0, 0), qr_label, font=font_badge_small)
    draw.text(
        (qr_center_x - (qr_label_box[2] - qr_label_box[0]) // 2, qr_y + 326),
        qr_label,
        fill=(0, 245, 212),
        font=font_badge_small,
    )
    qr_meta = "SOURCE · DEMO · DOCS"
    qr_meta_box = draw.textbbox((0, 0), qr_meta, font=font_badge_small)
    draw.text(
        (qr_center_x - (qr_meta_box[2] - qr_meta_box[0]) // 2, qr_y + 356),
        qr_meta,
        fill=(155, 180, 200),
        font=font_badge_small,
    )
    qr_corner_color = (255, 183, 3, 210)
    corner = 16
    for x1, y1, x2, y2 in (
        (qr_frame[0], qr_frame[1], qr_frame[0] + corner, qr_frame[1] + corner),
        (qr_frame[2], qr_frame[1], qr_frame[2] - corner, qr_frame[1] + corner),
        (qr_frame[0], qr_frame[3], qr_frame[0] + corner, qr_frame[3] - corner),
        (qr_frame[2], qr_frame[3], qr_frame[2] - corner, qr_frame[3] - corner),
    ):
        draw.line((x1, y1, x2, y1), fill=qr_corner_color, width=2)
        draw.line((x1, y1, x1, y2), fill=qr_corner_color, width=2)

    draw.text(
        (120, HEIGHT - 68),
        "SpeechRail  ·  born local, stays local",
        fill=(100, 135, 160),
        font=font_hud,
    )
    return img.convert("RGB")


def draw_audio_spectrum(draw: ImageDraw.ImageDraw, frame_idx: int):
    bars = spectrum_data[frame_idx]
    center_y = 885
    bar_w = 12
    gap = 8
    total_w = 64 * (bar_w + gap) - gap
    start_x = (WIDTH - total_w) // 2

    for b_idx in range(64):
        h = int(bars[b_idx] * 45)
        bx = start_x + b_idx * (bar_w + gap)
        by1 = center_y - h
        by2 = center_y + h
        ratio = b_idx / 64.0
        cr = int(0 + 240 * ratio)
        cg = int(220 * (1 - ratio * 0.5))
        cb = int(255 * (1 - ratio * 0.7))
        draw.rounded_rectangle([bx, by1, bx + bar_w, by2], radius=4, fill=(cr, cg, cb))


def draw_subtitle(draw: ImageDraw.ImageDraw, t: float):
    sub = get_current_subtitle(t)
    if not sub:
        return

    raw_text = sub["text"]
    lines = wrap_subtitle_smart(raw_text, max_w=1150)

    line_metrics = []
    max_line_w = 0
    total_text_h = 0
    line_gap = 10
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font_sub_zh)
        lw = bbox[2] - bbox[0]
        lh = bbox[3] - bbox[1]
        max_line_w = max(max_line_w, lw)
        line_metrics.append((line, lw, lh))
        total_text_h += lh

    total_text_h += line_gap * (len(lines) - 1)

    pad_x = 48
    pad_y = 16
    card_w = max_line_w + pad_x * 2
    card_h = total_text_h + pad_y * 2
    card_x1 = (WIDTH - card_w) // 2
    card_x2 = card_x1 + card_w

    card_y2 = 1050
    card_y1 = card_y2 - card_h

    draw_card(draw, card_x1, card_y1, card_x2, card_y2, (10, 15, 25), (45, 65, 95), radius=18)

    curr_y = card_y1 + pad_y
    for line, lw, lh in line_metrics:
        lx = card_x1 + (card_w - lw) // 2
        draw.text((lx, curr_y), line, fill=(255, 255, 255), font=font_sub_zh)
        curr_y += lh + line_gap


def render_body_frame(frame_idx: int) -> Image.Image:
    t = frame_idx / FPS
    img = Image.new("RGBA", (WIDTH, HEIGHT), (10, 14, 24, 255))
    draw = ImageDraw.Draw(img)

    # 1. Background Grid
    grid_color = (20, 28, 44, 140)
    for gx in range(0, WIDTH, 80):
        draw.line([(gx, 65), (gx, 860)], fill=grid_color, width=1)
    for gy in range(65, 860, 80):
        draw.line([(0, gy), (WIDTH, gy)], fill=grid_color, width=1)

    # 2. Audio-reactive ion field
    img = add_ion_field(img, t, frame_idx, strength=ION_BODY_STRENGTH)
    draw = ImageDraw.Draw(img)

    # 3. Top HUD
    draw_hud(draw, t, frame_idx)

    # 4. Act Content
    draw_act_content(draw, t, frame_idx)

    # 5. Dynamic Audio Spectrum Bars
    draw_audio_spectrum(draw, frame_idx)

    # 6. Subtitle Card
    draw_subtitle(draw, t)

    return img.convert("RGB")


def render_frame(frame_idx: int) -> Image.Image:
    """Render the cover, a continuous hand-off, or a body frame."""
    t = frame_idx / FPS
    if t < COVER_DURATION:
        return render_cover_frame(t)

    if t >= FINAL_PAGE_START:
        final_page = render_final_page(t)
        final_progress = min(max((t - FINAL_PAGE_START) / FINAL_PAGE_TRANSITION, 0.0), 1.0)
        if final_progress >= 1.0:
            return final_page
        body = render_body_frame(frame_idx)
        wipe_progress = final_progress * final_progress * (3.0 - 2.0 * final_progress)
        sweep_x = int(-400 + (WIDTH + 800) * wipe_progress)
        wipe_mask = Image.new("L", (WIDTH, HEIGHT), 0)
        wipe_draw = ImageDraw.Draw(wipe_mask)
        wipe_draw.polygon(
            [(0, 0), (sweep_x + 240, 0), (sweep_x - 240, HEIGHT), (0, HEIGHT)],
            fill=255,
        )
        frame = Image.composite(final_page, body, wipe_mask)

        # A narrow diagonal signal edge keeps the hand-off technical while
        # preventing the previous scene's text from showing through the card.
        transition_overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
        transition_draw = ImageDraw.Draw(transition_overlay)
        transition_draw.line(
            (sweep_x + 240, 80, sweep_x - 240, HEIGHT - 60),
            fill=(0, 245, 212, 190),
            width=3,
        )
        transition_draw.line(
            (sweep_x + 258, 80, sweep_x - 222, HEIGHT - 60),
            fill=(255, 183, 3, 100),
            width=1,
        )
        return Image.alpha_composite(frame.convert("RGBA"), transition_overlay).convert("RGB")

    body = render_body_frame(frame_idx)
    transition_end = COVER_DURATION + TRANSITION_DURATION
    if t >= transition_end:
        return body

    progress = min(max((t - COVER_DURATION) / TRANSITION_DURATION, 0.0), 1.0)
    cover_text_strength = max(0.0, 1.0 - progress / 0.30)
    body_progress = min(max((progress - 0.06) / 0.78, 0.0), 1.0)
    body_weight = body_progress * body_progress * (3.0 - 2.0 * body_progress)
    cover = render_cover_frame(COVER_DURATION, text_strength=cover_text_strength)
    frame = Image.blend(cover, body, body_weight)

    # The same diagonal signal rail bridges the two compositions during the
    # hand-off, so the transition reads as one system booting into its UI.
    sweep_x = int(-240 + (WIDTH + 480) * progress)
    transition_overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    transition_draw = ImageDraw.Draw(transition_overlay)
    glow_alpha = int(125 * math.sin(math.pi * progress))
    transition_draw.line(
        (sweep_x, 80, sweep_x - 320, HEIGHT - 60),
        fill=(0, 245, 212, glow_alpha),
        width=3,
    )
    return Image.alpha_composite(frame.convert("RGBA"), transition_overlay).convert("RGB")


def main():
    print(
        "--- Starting Video Render Pipeline V2 "
        f"({TOTAL_FRAMES} frames @ 30fps -> {OUTPUT_VIDEO}) ---"
    )

    cmd = [
        "ffmpeg",
        "-y",
        "-f",
        "rawvideo",
        "-vcodec",
        "rawvideo",
        "-s",
        f"{WIDTH}x{HEIGHT}",
        "-pix_fmt",
        "rgb24",
        "-r",
        str(FPS),
        "-i",
        "-",
        "-i",
        str(AUDIO_FILE),
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "320k",
        "-shortest",
        str(OUTPUT_VIDEO),
    ]

    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
    )

    try:
        for f_idx in range(TOTAL_FRAMES):
            frame_img = render_frame(f_idx)
            proc.stdin.write(frame_img.tobytes())
            if f_idx % 300 == 0:
                print(
                    f"Rendered frame {f_idx}/{TOTAL_FRAMES} "
                    f"({f_idx / FPS:.1f}s / 90.0s, "
                    f"{f_idx * 100 // TOTAL_FRAMES}%)"
                )

        proc.stdin.close()
        stderr_output = proc.stderr.read().decode()
        proc.wait()

        if proc.returncode != 0:
            print("FFmpeg Error:", stderr_output)
            sys.exit(1)

        print(f"SUCCESS! V2 Video created at: {OUTPUT_VIDEO}")

    except Exception as e:
        print(f"Exception during rendering: {e}")
        proc.kill()
        sys.exit(1)


if __name__ == "__main__":
    main()
