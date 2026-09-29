"""
URL utility functions

Functions for normalizing and hashing URLs.
"""

import hashlib
import re


def url_hash(url: str) -> str:
    """
    Generate a short hash from a URL.
    
    Args:
        url: URL string to hash
        
    Returns:
        16-character hexadecimal hash
    """
    return hashlib.sha256(url.encode()).hexdigest()[:16]


def normalize_youtube_url(url: str) -> str:
    """
    Convert YouTube Shorts URLs to regular video URLs.
    Shorts URLs have more aggressive bot detection.
    
    Args:
        url: YouTube URL (can be Shorts or regular format)
        
    Returns:
        Normalized YouTube URL (regular format)
    """
    # YouTube Shorts URL pattern: https://www.youtube.com/shorts/VIDEO_ID
    shorts_pattern = r'youtube\.com/shorts/([a-zA-Z0-9_-]+)'
    match = re.search(shorts_pattern, url)
    if match:
        video_id = match.group(1)
        normalized = f"https://www.youtube.com/watch?v={video_id}"
        print(f"     [yt-dlp] ℹ️  Converted Shorts URL to regular video URL: {normalized}")
        return normalized
    return url

