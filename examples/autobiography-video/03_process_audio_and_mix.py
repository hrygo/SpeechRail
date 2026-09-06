#!/usr/bin/env python3
"""
Process V2 Hook audio segments with dynamic pacing, assemble precisely into 90.0s timeline,
generate frame-accurate SRT subtitles, and mix with BGM using sidechain audio ducking.
"""

import json
import re
import subprocess
from pathlib import Path

BUILD_DIR = Path(__file__).parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
RAW_META = BUILD_DIR / "segments_meta_v2.json"
PROCESSED_DIR = BUILD_DIR / "audio_processed_v2"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
SHOWCASE_META = BUILD_DIR / "voice_showcase_meta_v1.json"
SHOWCASE_PROCESSED_DIR = BUILD_DIR / "audio_showcase_processed_v1"
SHOWCASE_PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

# Speed tuning for tight, energetic delivery
SPEED_MAP = {
    1: 1.34,  # Fast, punchy hook in first 10-12s
    2: 1.28,
    3: 1.28,
    4: 1.28,
    5: 1.15,  # Showcase voices clearly
    6: 1.34,  # Keep the CTA spacious while preserving the 90s showcase tail
}

# Act start targets in the 90-second video
ACT_START_TARGETS = {
    1: 0.5,
    2: 12.8,
    3: 27.2,
    4: 41.8,
    5: 56.6,
    6: 69.2,
}
SHOWCASE_START = 81.2
SHOWCASE_GAP = 0.18
SHOWCASE_BOUNDARY_PAUSE = 0.05
DURATION = 90.0
DEFAULT_PAUSE_BEFORE = 0.20
ACT_BOUNDARY_PAUSE = 0.12

# Mastering targets for a speech-led streaming demo. The per-clip controls below
# are deliberately conservative for formal narration: they correct obvious
# TTS-to-TTS jumps without flattening human-like emphasis inside a sentence.
MASTER_TARGET_LUFS = -16.0
MASTER_TARGET_TRUE_PEAK = -1.5
MASTER_TARGET_LRA = 7.0
FORMAL_REFERENCE_LUFS = -22.5
FORMAL_LEVEL_STRENGTH = 0.45
FORMAL_MAX_GAIN_DB = 1.5
SHOWCASE_REFERENCE_LUFS = -20.0
SHOWCASE_LEVEL_STRENGTH = 1.0
SHOWCASE_MAX_GAIN_DB = 4.5


def format_srt_time(seconds: float) -> str:
    millis = int((seconds - int(seconds)) * 1000)
    seconds = int(seconds)
    minutes = seconds // 60
    hours = minutes // 60
    minutes = minutes % 60
    seconds = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def get_audio_duration(file_path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(file_path),
    ]
    res = subprocess.check_output(cmd).decode().strip()
    return float(res)


def measure_loudness(file_path: Path) -> dict[str, float]:
    """Measure EBU R128 loudness metrics without writing an intermediate file."""
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(file_path),
        "-af",
        "loudnorm=I=-16:TP=-1.5:LRA=7:print_format=json",
        "-f",
        "null",
        "-",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    matches = re.findall(r"\{\s*\"input_i\".*?\}", result.stderr, flags=re.DOTALL)
    if not matches:
        raise RuntimeError(f"Unable to parse loudness metrics for {file_path}")
    metrics = json.loads(matches[-1])
    return {
        key: float(metrics[key]) for key in ("input_i", "input_tp", "input_lra", "input_thresh")
    }


def calculate_clip_gain(
    input_lufs: float,
    reference_lufs: float,
    strength: float,
    max_gain_db: float,
) -> float:
    """Apply a bounded loudness correction while preserving clip dynamics."""
    correction = (reference_lufs - input_lufs) * strength
    bounded = max(-max_gain_db, min(max_gain_db, correction))
    return round(bounded, 2)


def build_master_filter(loudnorm_options: str, output_label: str) -> str:
    """Build the shared ducking graph for loudness measurement and rendering."""
    return (
        "[0:a]aformat=channel_layouts=stereo,volume=1.05[voice];"
        "[1:a]aformat=channel_layouts=stereo,highpass=f=140,lowpass=f=7500,"
        "volume='if(between(t,56.6,69.2),0.04,0.14)':eval=frame[bgm_raw];"
        "[bgm_raw][voice]"
        "sidechaincompress=threshold=0.035:ratio=10:attack=15:release=350:"
        "link=maximum[bgm_ducked];"
        "[bgm_ducked][voice]"
        "amix=inputs=2:duration=first:dropout_transition=0:normalize=0,"
        f"apad=whole_dur={DURATION:.1f}[pre_master];"
        f"[pre_master]loudnorm={loudnorm_options}[{output_label}]"
    )


def main():
    with RAW_META.open(encoding="utf-8") as f:
        raw_segments = json.load(f)

    processed_segments = []
    print("--- Step 2: Processing and retiming V2 audio segments ---")
    for seg in raw_segments:
        speed = seg.get("speed_override", SPEED_MAP[seg["act"]])
        raw_path = Path(seg["path"])
        proc_path = PROCESSED_DIR / f"{seg['id']}_proc.wav"
        source_metrics = measure_loudness(raw_path)
        level_gain_db = calculate_clip_gain(
            source_metrics["input_i"],
            FORMAL_REFERENCE_LUFS,
            FORMAL_LEVEL_STRENGTH,
            FORMAL_MAX_GAIN_DB,
        )
        volume_suffix = f",volume={level_gain_db:.2f}dB" if level_gain_db else ""

        cmd = [
            "ffmpeg",
            "-y",
            "-i",
            str(raw_path),
            "-filter:a",
            f"atempo={speed}{volume_suffix}",
            "-ar",
            "44100",
            str(proc_path),
        ]
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        dur = get_audio_duration(proc_path)
        processed_segments.append(
            {
                **seg,
                "proc_path": str(proc_path),
                "proc_duration": dur,
                "speed": speed,
                "source_lufs": round(source_metrics["input_i"], 2),
                "level_gain_db": level_gain_db,
            }
        )

    # Assemble timeline
    timeline = []
    current_act = 0
    current_t = 0.0

    for seg in processed_segments:
        act = seg["act"]
        if act != current_act:
            current_act = act
            target_t = ACT_START_TARGETS[act]
            # A longer regenerated sentence must not overlap the next Act's
            # fixed visual target. Keep a short spoken boundary pause when the
            # previous Act runs past that target.
            current_t = max(target_t, current_t + ACT_BOUNDARY_PAUSE) if timeline else target_t
        else:
            current_t += float(seg.get("pause_before", DEFAULT_PAUSE_BEFORE))

        start_t = current_t
        end_t = start_t + seg["proc_duration"]
        timeline.append(
            {
                **seg,
                "start": round(start_t, 3),
                "end": round(end_t, 3),
            }
        )
        current_t = end_t
        preview = seg["text"][:25]
        timestamp = f"[{format_srt_time(start_t)} -> {format_srt_time(end_t)}]"
        print(f"{timestamp} Act {act} ({seg['voice']}):")
        print(f"  {preview}...")

    # Export SRT subtitles
    srt_path = BUILD_DIR / "speechrail_autobiography.srt"
    with srt_path.open("w", encoding="utf-8") as f:
        for idx, item in enumerate(timeline, 1):
            f.write(f"{idx}\n")
            f.write(f"{format_srt_time(item['start'])} --> {format_srt_time(item['end'])}\n")
            f.write(f"{item['text']}\n\n")
    print(f"\nCreated SRT: {srt_path}")

    # Export timeline JSON
    timeline_file = BUILD_DIR / "timeline.json"
    with timeline_file.open("w", encoding="utf-8") as f:
        json.dump(timeline, f, ensure_ascii=False, indent=2)

    # Add the six voices that were only listed in Act 5 to the quiet postscript
    # after the formal narration. Keep their timeline separate from subtitles.
    showcase_timeline = []
    showcase_meta = []
    if SHOWCASE_META.exists():
        with SHOWCASE_META.open(encoding="utf-8") as f:
            showcase_meta = json.load(f)

    showcase_t = max(
        SHOWCASE_START,
        (timeline[-1]["end"] + SHOWCASE_BOUNDARY_PAUSE) if timeline else SHOWCASE_START,
    )
    for seg in showcase_meta:
        speed = seg.get("speed_override", 1.0)
        raw_path = Path(seg["path"])
        proc_path = SHOWCASE_PROCESSED_DIR / f"{seg['id']}_proc.wav"
        source_metrics = measure_loudness(raw_path)
        level_gain_db = calculate_clip_gain(
            source_metrics["input_i"],
            SHOWCASE_REFERENCE_LUFS,
            SHOWCASE_LEVEL_STRENGTH,
            SHOWCASE_MAX_GAIN_DB,
        )
        volume_suffix = f",volume={level_gain_db:.2f}dB" if level_gain_db else ""
        cmd = [
            "ffmpeg",
            "-y",
            "-i",
            str(raw_path),
            "-filter:a",
            f"atempo={speed}{volume_suffix}",
            "-ar",
            "44100",
            str(proc_path),
        ]
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        dur = get_audio_duration(proc_path)
        start_t = round(showcase_t, 3)
        end_t = round(start_t + dur, 3)
        if end_t > DURATION:
            raise RuntimeError(f"Voice showcase exceeds {DURATION:.1f}s: {seg['voice']}")
        showcase_timeline.append(
            {
                **seg,
                "proc_path": str(proc_path),
                "proc_duration": dur,
                "speed": speed,
                "source_lufs": round(source_metrics["input_i"], 2),
                "level_gain_db": level_gain_db,
                "start": start_t,
                "end": end_t,
                "showcase": True,
            }
        )
        showcase_t = end_t + SHOWCASE_GAP
        print(
            f"[{format_srt_time(start_t)} -> {format_srt_time(end_t)}] "
            f"Showcase ({seg['voice']}): {seg['description']}"
        )

    showcase_timeline_file = BUILD_DIR / "voice_showcase_timeline.json"
    with showcase_timeline_file.open("w", encoding="utf-8") as f:
        json.dump(showcase_timeline, f, ensure_ascii=False, indent=2)

    # 1. Assemble pure voiceover into 90s track
    inputs = []
    filter_parts = []
    voice_items = [*timeline, *showcase_timeline]
    for i, item in enumerate(voice_items):
        inputs.extend(["-i", item["proc_path"]])
        delay_ms = int(item["start"] * 1000)
        filter_parts.append(f"[{i}:a]adelay={delay_ms}|{delay_ms}[a{i}];")

    mix_inputs = "".join(f"[a{i}]" for i in range(len(voice_items)))
    voice_mix_filter = ":".join(
        (
            f"{mix_inputs}amix=inputs={len(voice_items)}",
            "dropout_transition=0",
            f"normalize=0,apad=whole_dur={DURATION:.1f}[voice_out]",
        )
    )
    filter_cmd = "".join(filter_parts) + voice_mix_filter

    voice_only_path = BUILD_DIR / "voiceover_90s.wav"
    cmd = [
        "ffmpeg",
        "-y",
        *inputs,
        "-filter_complex",
        filter_cmd,
        "-map",
        "[voice_out]",
        "-t",
        f"{DURATION:.1f}",
        "-ar",
        "44100",
        "-ac",
        "2",
        str(voice_only_path),
    ]
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Created voiceover track: {voice_only_path}")

    # 2. Master Mix: keep the bed behind speech and make Act 5 voice changes audible.
    bgm_path = BUILD_DIR / "bgm_90s.wav"
    master_mix_path = BUILD_DIR / "master_audio_90s.wav"

    pass1_filter = build_master_filter(
        f"I={MASTER_TARGET_LUFS:.1f}:TP={MASTER_TARGET_TRUE_PEAK:.1f}:"
        f"LRA={MASTER_TARGET_LRA:.1f}:print_format=json",
        "loudness",
    )
    pass1_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(voice_only_path),
        "-i",
        str(bgm_path),
        "-filter_complex",
        pass1_filter,
        "-map",
        "[loudness]",
        "-f",
        "null",
        "-",
    ]
    pass1 = subprocess.run(pass1_cmd, capture_output=True, text=True, check=True)
    matches = re.findall(r"\{\s*\"input_i\".*?\}", pass1.stderr, flags=re.DOTALL)
    if not matches:
        raise RuntimeError("Unable to parse master loudness measurement")
    measured = json.loads(matches[-1])
    measured_options = (
        f"I={MASTER_TARGET_LUFS:.1f}:TP={MASTER_TARGET_TRUE_PEAK:.1f}:"
        f"LRA={MASTER_TARGET_LRA:.1f}:"
        f"measured_I={float(measured['input_i']):.3f}:"
        f"measured_TP={float(measured['input_tp']):.3f}:"
        f"measured_LRA={float(measured['input_lra']):.3f}:"
        f"measured_thresh={float(measured['input_thresh']):.3f}:"
        f"offset={float(measured['target_offset']):.3f}:"
        "linear=true:print_format=summary"
    )
    cmd_mix = [
        "ffmpeg",
        "-y",
        "-i",
        str(voice_only_path),
        "-i",
        str(bgm_path),
        "-filter_complex",
        build_master_filter(measured_options, "master"),
        "-map",
        "[master]",
        "-t",
        "90.0",
        "-ar",
        "44100",
        "-ac",
        "2",
        str(master_mix_path),
    ]
    subprocess.check_call(cmd_mix, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Master mixed audio with Ducking created: {master_mix_path}")
    dur = get_audio_duration(master_mix_path)
    print(f"Master Audio Duration: {dur:.2f} seconds!")


if __name__ == "__main__":
    main()
