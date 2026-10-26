#!/usr/bin/env python3
"""把楼层管理下载的全部 PNG/JPG 户型图增量描摹成纯路径 SVG。

输出到每栋楼的 vectors/，文件名与 images/ 中原图一致，仅扩展名改为 .svg。
采用黑白线稿模式并关闭小区域过滤，避免门弧、楼梯踏步和房间编号被抹掉。
原始图片不会被修改。

依赖（在 flutter_upload 项目根目录执行一次）：
  python3 -m pip install --target .vector-deps 'vtracer>=0.6,<0.7'

用法：
  python3 tool/vectorize_floor_maps.py --root ~/floor_data
  python3 tool/vectorize_floor_maps.py --root ~/floor_data --force

stdout 使用 JSON Lines 报告 progress/result，供 Flutter 页面显示实时进度。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
LOCAL_DEPS = PROJECT_ROOT / ".vector-deps"
if LOCAL_DEPS.is_dir():
    sys.path.insert(0, str(LOCAL_DEPS))

GENERATOR_MARK = "flutter-upload-floor-vector:v1"
SUPPORTED_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif"}


@dataclass(frozen=True)
class VectorJob:
    building: str
    floor: str
    source: Path
    target: Path


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def load_jobs(root: Path) -> list[VectorJob]:
    jobs: list[VectorJob] = []
    for manifest_path in sorted(root.glob("*/floors.json")):
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                manifest = json.load(handle)
        except (OSError, ValueError) as exc:
            print(f"跳过无法读取的 {manifest_path}: {exc}", file=sys.stderr)
            continue
        if not isinstance(manifest, dict):
            continue
        building_dir = manifest_path.parent
        building = str(manifest.get("buildingName") or building_dir.name)
        for floor in manifest.get("floors") or []:
            if not isinstance(floor, dict):
                continue
            raw_image = str(floor.get("image") or "").strip()
            if not raw_image:
                continue
            source = Path(raw_image).expanduser()
            if not source.is_absolute():
                source = building_dir / source
            if source.suffix.lower() not in SUPPORTED_SUFFIXES:
                continue
            target = building_dir / "vectors" / f"{source.stem}.svg"
            jobs.append(
                VectorJob(
                    building=building,
                    floor=str(floor.get("name") or floor.get("id") or source.stem),
                    source=source,
                    target=target,
                )
            )
    return jobs


def needs_conversion(job: VectorJob, force: bool) -> bool:
    if force or not job.target.is_file():
        return True
    try:
        if job.target.stat().st_mtime_ns < job.source.stat().st_mtime_ns:
            return True
        with job.target.open("r", encoding="utf-8") as handle:
            return GENERATOR_MARK not in handle.read(512)
    except OSError:
        return True


def finalize_svg(temp_path: Path) -> int:
    """校验纯矢量内容，补 viewBox，并返回路径数。"""
    text = temp_path.read_text(encoding="utf-8")
    root = ET.fromstring(text)
    if root.tag.rsplit("}", 1)[-1] != "svg":
        raise ValueError("输出根节点不是 SVG")
    tags = [node.tag.rsplit("}", 1)[-1] for node in root.iter()]
    if "image" in tags:
        raise ValueError("SVG 含内嵌位图，已拒绝")
    path_count = tags.count("path")
    if path_count == 0:
        raise ValueError("未生成矢量路径（原图可能为空白或已损坏）")

    if "viewBox" not in root.attrib:
        width = root.attrib.get("width", "").removesuffix("px")
        height = root.attrib.get("height", "").removesuffix("px")
        try:
            if float(width) > 0 and float(height) > 0:
                text = re.sub(
                    r"<svg\b",
                    f'<svg viewBox="0 0 {width} {height}"',
                    text,
                    count=1,
                )
        except ValueError:
            pass

    marker = f"<!-- {GENERATOR_MARK}; paths={path_count} -->\n"
    if text.startswith("<?xml"):
        declaration_end = text.find("?>")
        if declaration_end >= 0:
            declaration_end += 2
            text = text[:declaration_end] + "\n" + marker + text[declaration_end:]
        else:
            text = marker + text
    else:
        text = marker + text
    temp_path.write_text(text, encoding="utf-8")
    return path_count


def convert_one(job: VectorJob, vtracer_module) -> int:
    if not job.source.is_file():
        raise FileNotFoundError(f"原图不存在：{job.source}")
    job.target.parent.mkdir(parents=True, exist_ok=True)
    temp_path = job.target.with_name(
        f".{job.target.stem}.{os.getpid()}.tmp.svg"
    )
    try:
        vtracer_module.convert_image_to_svg_py(
            str(job.source),
            str(temp_path),
            colormode="binary",
            hierarchical="cutout",
            mode="polygon",
            filter_speckle=0,
            corner_threshold=60,
            length_threshold=1.0,
            max_iterations=10,
            splice_threshold=45,
            path_precision=3,
        )
        path_count = finalize_svg(temp_path)
        os.replace(temp_path, job.target)
        return path_count
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="全量楼层户型图 SVG 矢量化")
    parser.add_argument("--root", required=True, help="楼层爬取输出目录")
    parser.add_argument("--force", action="store_true", help="忽略缓存全部重建")
    args = parser.parse_args()

    try:
        import vtracer  # type: ignore
    except ImportError:
        print(
            "缺少 vtracer。请在 flutter_upload 项目根目录执行：\n"
            "python3 -m pip install --target .vector-deps 'vtracer>=0.6,<0.7'",
            file=sys.stderr,
        )
        return 2

    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        print(f"楼层输出目录不存在：{root}", file=sys.stderr)
        return 2

    jobs = load_jobs(root)
    total = len(jobs)
    converted = skipped = failed = 0
    svg_bytes = 0
    started = time.monotonic()

    for index, job in enumerate(jobs, start=1):
        current = f"{job.building} / {job.floor}"
        error = ""
        try:
            if needs_conversion(job, args.force):
                convert_one(job, vtracer)
                converted += 1
            else:
                skipped += 1
            svg_bytes += job.target.stat().st_size
        except Exception as exc:  # 单图失败不阻断其它楼层
            failed += 1
            error = str(exc)
        emit(
            {
                "type": "progress",
                "done": index,
                "total": total,
                "converted": converted,
                "skipped": skipped,
                "failed": failed,
                "current": current,
                "error": error,
            }
        )

    result = {
        "type": "result",
        "total": total,
        "converted": converted,
        "skipped": skipped,
        "failed": failed,
        "svgBytes": svg_bytes,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "outputRoot": str(root),
    }
    emit(result)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
