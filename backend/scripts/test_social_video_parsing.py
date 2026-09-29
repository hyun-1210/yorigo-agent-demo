"""
Quick test script for social video parsing.

Usage:
  python backend/scripts/test_social_video_parsing.py <instagram_or_tiktok_url>
  python backend/scripts/test_social_video_parsing.py <url> --skip-media
"""

import argparse
import json
import sys
import tempfile
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from services.youtube_service import YouTubeService


def main() -> None:
    parser = argparse.ArgumentParser(description="Test Instagram/TikTok video parsing")
    parser.add_argument("url", help="Instagram reel/post or TikTok video URL")
    parser.add_argument(
        "--skip-media",
        action="store_true",
        help="Only test metadata parsing (skip audio/frame extraction)",
    )
    args = parser.parse_args()

    svc = YouTubeService()

    print("\n[1/3] Extracting metadata...")
    info, cookie_id = svc.extract_with_ytdlp(args.url)
    print("Metadata extraction success")
    print(json.dumps(
        {
            "id": info.get("id"),
            "extractor_key": info.get("extractor_key"),
            "title": info.get("title"),
            "duration": info.get("duration"),
            "uploader": info.get("uploader"),
            "direct_video_url": bool(info.get("direct_video_url")),
            "cookie_id": cookie_id,
        },
        ensure_ascii=False,
        indent=2,
    ))

    if args.skip_media:
        print("\nSkipped media extraction by request.")
        return

    with tempfile.TemporaryDirectory(prefix="social_parse_test_") as tmp_dir:
        tmp = Path(tmp_dir)

        print("\n[2/3] Downloading audio...")
        audio_path = svc.download_audio(args.url, str(tmp), cookie_id)
        print(f"Audio path: {audio_path}")
        print(f"Audio exists: {Path(audio_path).exists()} size={Path(audio_path).stat().st_size if Path(audio_path).exists() else 0}")

        print("\n[3/3] Sampling frames...")
        frames = svc.sample_frames_to_tmp(args.url, str(tmp), fps=0.3)
        print(f"Extracted frames: {len(frames)}")
        if frames:
            print(f"First frame: {frames[0]}")

    print("\nSocial video parsing test completed successfully.")


if __name__ == "__main__":
    main()
