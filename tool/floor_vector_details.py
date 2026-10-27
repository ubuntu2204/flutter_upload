#!/usr/bin/env python3
"""户型图文字与圆弧门识别，输出可编辑 SVG 图层。"""

from __future__ import annotations

import csv
import io
import json
import math
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape

import cv2
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
FONT_FAMILY = "Noto Sans CJK SC, Microsoft YaHei, Arial, sans-serif"


@dataclass
class OcrWord:
    index: int
    text: str
    confidence: float
    box: tuple[float, float, float, float]

    @property
    def center(self) -> tuple[float, float]:
        x, y, w, h = self.box
        return x + w / 2, y + h / 2


@dataclass
class TextLabel:
    text: str
    box: tuple[float, float, float, float]
    font_size: float
    kind: str = "room"
    mask_box: tuple[float, float, float, float] | None = None

    def to_svg(self) -> str:
        x, y, w, h = self.box
        baseline = y + h / 2 + self.font_size * 0.35
        return (
            f'<text x="{x + w / 2:.2f}" y="{baseline:.2f}" '
            f'font-size="{self.font_size:.2f}" text-anchor="middle" '
            f'data-kind="{self.kind}">{escape(self.text)}</text>'
        )


@dataclass
class DoorSymbol:
    cx: float
    cy: float
    radius: float
    start_angle: float
    end_angle: float
    leaf_angle: float
    source_points: np.ndarray
    score: float

    def _point(self, angle: float) -> tuple[float, float]:
        return (
            self.cx + self.radius * math.cos(angle),
            self.cy + self.radius * math.sin(angle),
        )

    def to_svg(self) -> str:
        start = self._point(self.start_angle)
        end = self._point(self.end_angle)
        leaf = self._point(self.leaf_angle)
        large_arc = 1 if self.end_angle - self.start_angle > math.pi else 0
        width = max(1.0, self.radius * 0.045)
        return (
            f'<path data-kind="door" d="M {start[0]:.2f} {start[1]:.2f} '
            f'A {self.radius:.2f} {self.radius:.2f} 0 {large_arc} 1 '
            f'{end[0]:.2f} {end[1]:.2f} M {self.cx:.2f} {self.cy:.2f} '
            f'L {leaf[0]:.2f} {leaf[1]:.2f}" stroke-width="{width:.2f}"/>'
        )


@dataclass
class DetailLayer:
    image: np.ndarray
    labels: list[TextLabel] = field(default_factory=list)
    doors: list[DoorSymbol] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def title_count(self) -> int:
        return sum(label.kind == "title" for label in self.labels)

    def svg_groups(self) -> str:
        groups = []
        if self.doors:
            paths = "".join(door.to_svg() for door in self.doors)
            groups.append(
                '<g id="doors" fill="none" stroke="#1f2937" '
                'stroke-linecap="round" stroke-linejoin="round">'
                f"{paths}</g>"
            )
        room_labels = [label for label in self.labels if label.kind == "room"]
        titles = [label for label in self.labels if label.kind == "title"]
        if room_labels:
            groups.append(
                f'<g id="room-labels" fill="#111827" font-family="{FONT_FAMILY}">'
                + "".join(label.to_svg() for label in room_labels)
                + "</g>"
            )
        if titles:
            groups.append(
                f'<g id="drawing-title" fill="#111827" font-family="{FONT_FAMILY}">'
                + "".join(label.to_svg() for label in titles)
                + "</g>"
            )
        return "".join(groups)


@dataclass
class RoomGeometry:
    number: str
    polygon: np.ndarray
    anchor: tuple[float, float]


def _load_json(path: Path | None) -> dict:
    if path is None or not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _cad_data(detail: dict) -> dict:
    stats = detail.get("statisticsRoomVo") or {}
    for key in ("cadIdentifyData", "rawData"):
        raw = stats.get(key)
        if not raw:
            continue
        try:
            value = json.loads(raw) if isinstance(raw, str) else raw
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("rooms"):
            return value
    return {}


def _point_inside(polygon: np.ndarray, point: tuple[float, float]) -> bool:
    return cv2.pointPolygonTest(
        polygon.astype(np.float32), (float(point[0]), float(point[1])), False
    ) >= 0


def _room_anchor(polygon: np.ndarray) -> tuple[float, float]:
    anchor = tuple(np.mean(polygon, axis=0))
    if _point_inside(polygon, anchor):
        return float(anchor[0]), float(anchor[1])
    x, y, w, h = cv2.boundingRect(polygon.astype(np.int32))
    center = (x + w / 2, y + h / 2)
    if _point_inside(polygon, center):
        return center
    mask = np.zeros((max(h + 4, 1), max(w + 4, 1)), dtype=np.uint8)
    shifted = polygon - np.array([x - 2, y - 2])
    cv2.fillPoly(mask, [shifted.astype(np.int32)], 1)
    if not mask.any():
        return center
    distance = cv2.distanceTransform(mask, cv2.DIST_L2, 3)
    _, _, _, maximum = cv2.minMaxLoc(distance)
    return x - 2 + maximum[0], y - 2 + maximum[1]


def _rooms_and_numbers(
    detail: dict, image_size: tuple[int, int]
) -> tuple[list[RoomGeometry], set[str], tuple[int, int] | None]:
    cad = _cad_data(detail)
    width, height = image_size
    size = cad.get("size") or {}
    cad_width = int(size.get("width") or width)
    cad_height = int(size.get("height") or height)
    sx, sy = width / max(cad_width, 1), height / max(cad_height, 1)
    rooms = []
    numbers = set()
    for raw in cad.get("rooms") or []:
        if not isinstance(raw, dict):
            continue
        room = raw.get("room") or {}
        number = str(raw.get("roomNo") or room.get("roomNo") or "").strip()
        points = []
        for vertex in raw.get("vertex") or []:
            try:
                points.append([float(vertex["x"]) * sx, float(vertex["y"]) * sy])
            except (KeyError, TypeError, ValueError):
                continue
        if number:
            numbers.add(_normalize_label(number))
        if not number or len(points) < 3:
            continue
        polygon = np.asarray(points, dtype=np.float32)
        if cv2.contourArea(polygon) < 16:
            continue
        rooms.append(RoomGeometry(number, polygon, _room_anchor(polygon)))
    for room in detail.get("roomDetailVo") or []:
        if isinstance(room, dict) and room.get("roomNo"):
            numbers.add(_normalize_label(str(room["roomNo"])))
    return rooms, numbers, (cad_width, cad_height) if cad else None


def _normalize_label(text: str) -> str:
    return re.sub(r"\s+", "", text).upper()


def _ocr(image: Image.Image, warnings: list[str], psm: int = 6) -> list[OcrWord]:
    scale = min(1.0, 3000 / max(image.size))
    ocr_image = image
    if scale < 1.0:
        ocr_image = image.resize(
            (round(image.width * scale), round(image.height * scale)),
            Image.Resampling.LANCZOS,
        )
    try:
        with tempfile.TemporaryDirectory(prefix="floor-ocr-") as temp:
            path = Path(temp) / "source.png"
            ocr_image.save(path)
            completed = subprocess.run(
                [
                    "tesseract",
                    str(path),
                    "stdout",
                    "-l",
                    "chi_sim+eng",
                    "--psm",
                    str(psm),
                    "tsv",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=90,
                check=False,
                env={"OMP_THREAD_LIMIT": "1"},
            )
    except (OSError, subprocess.TimeoutExpired) as exc:
        warnings.append(f"OCR 不可用：{exc}")
        return []
    if completed.returncode != 0:
        warnings.append(
            "OCR 失败：" + completed.stderr.decode("utf-8", "replace")[:200]
        )
        return []
    words = []
    reader = csv.DictReader(
        io.StringIO(completed.stdout.decode("utf-8", "replace")), delimiter="\t"
    )
    for row in reader:
        text = (row.get("text") or "").strip()
        if not text:
            continue
        try:
            confidence = float(row["conf"])
            x, y, w, h = (float(row[key]) / scale for key in ("left", "top", "width", "height"))
        except (KeyError, TypeError, ValueError):
            continue
        if confidence >= 10 and w > 0 and h > 0:
            words.append(OcrWord(len(words), text, confidence, (x, y, w, h)))
    return words


def _chinese_count(text: str) -> int:
    return len(re.findall(r"[\u3400-\u9fff]", text))


def _median_number_height(words: list[OcrWord]) -> float:
    heights = [
        word.box[3]
        for word in words
        if word.confidence >= 35 and re.search(r"\d", word.text)
    ]
    return float(np.median(heights)) if heights else 14.0


def _title_label(
    words: list[OcrWord], image_size: tuple[int, int], generated: str
) -> tuple[TextLabel | None, set[int]]:
    width, height = image_size
    number_height = _median_number_height(words)
    large = [
        word
        for word in words
        if word.box[3] >= max(22, number_height * 1.8)
        and word.center[1] > height * 0.42
        and width * 0.08 < word.center[0] < width * 0.92
    ]
    seeds = [word for word in large if _chinese_count(word.text)]
    if not seeds:
        return None, set()
    clusters: list[list[OcrWord]] = []
    for seed in seeds:
        sx, sy = seed.center
        placed = False
        for cluster in clusters:
            if any(
                abs(sy - other.center[1]) < max(seed.box[3], other.box[3]) * 0.8
                and abs(sx - other.center[0])
                < (seed.box[2] + other.box[2]) / 2
                + max(seed.box[3], other.box[3]) * 1.8
                for other in cluster
            ):
                cluster.append(seed)
                placed = True
                break
        if not placed:
            clusters.append([seed])
    best = None
    best_score = -1.0
    for cluster in clusters:
        if len(cluster) < 2 and not any("平" in word.text for word in cluster):
            continue
        cx = float(np.mean([word.center[0] for word in cluster]))
        cy = float(np.mean([word.center[1] for word in cluster]))
        score = sum(_chinese_count(word.text) for word in cluster) * 100
        score += sum(word.box[2] for word in cluster)
        score -= abs(cx - width / 2) * 0.2
        if cy < height * 0.45:
            score -= 500
        if score > best_score:
            best, best_score = cluster, score
    if not best:
        return None, set()

    expanded = list(best)
    for word in large:
        if word in expanded:
            continue
        if any(
            abs(word.center[1] - other.center[1])
            < max(word.box[3], other.box[3]) * 0.65
            and abs(word.center[0] - other.center[0])
            < (word.box[2] + other.box[2]) / 2
            + max(word.box[3], other.box[3]) * 1.5
            for other in best
        ):
            expanded.append(word)
    x0 = min(word.box[0] for word in expanded)
    y0 = min(word.box[1] for word in expanded)
    x1 = max(word.box[0] + word.box[2] for word in expanded)
    y1 = max(word.box[1] + word.box[3] for word in expanded)
    recognized = "".join(
        word.text
        for word in sorted(expanded, key=lambda item: item.center[0])
        if _chinese_count(word.text) or re.match(r"^[0-9#号]+$", word.text)
    )
    recognized = re.sub(r"\s+", "", recognized)
    if recognized.endswith("平面"):
        recognized += "图"
    if recognized and sorted(recognized) == sorted(generated):
        text = generated
    else:
        text = recognized if "平面" in recognized and _chinese_count(recognized) >= 4 else generated
    heights = [word.box[3] for word in expanded if _chinese_count(word.text)]
    font_size = float(np.median(heights)) * 1.05 if heights else (y1 - y0) * 0.8
    units = sum(1.0 if _chinese_count(char) else 0.62 for char in text)
    font_size = min(font_size, (x1 - x0) / max(units, 1))
    pad = max(2.0, font_size * 0.08)
    box = (x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad)
    return TextLabel(text, box, font_size, "title"), {word.index for word in expanded}


def _floor_name(floor: str) -> str:
    text = floor.strip()
    match = re.fullmatch(r"([FB])(\d{1,2})", text, re.IGNORECASE)
    if not match:
        return text
    number = int(match.group(2))
    digits = "零一二三四五六七八九"
    if number <= 10:
        chinese = "十" if number == 10 else digits[number]
    elif number < 20:
        chinese = "十" + digits[number % 10]
    else:
        chinese = digits[number // 10] + "十" + (digits[number % 10] if number % 10 else "")
    return ("地下" if match.group(1).upper() == "B" else "") + chinese + "层"


def generated_title(building: str, floor: str) -> str:
    name = re.sub(r"[（(][^）)]*校区[^）)]*[）)]", "", building).strip()
    floor_name = _floor_name(floor)
    if floor_name.endswith("平面图"):
        return f"{name}{floor_name}"
    return f"{name}{floor_name}平面图"


def _extend_suffix(word: OcrWord, number: str, words: list[OcrWord]) -> OcrWord:
    normalized = _normalize_label(word.text)
    if normalized == number or not number.startswith(normalized):
        return word
    suffix = number[len(normalized) :]
    if not suffix.isalpha():
        return word
    candidates = []
    for other in words:
        if other.index == word.index or _normalize_label(other.text) != suffix:
            continue
        x, y, w, h = word.box
        ox, oy, ow, oh = other.box
        vertical = min(y + h, oy + oh) - max(y, oy)
        gap = max(0, max(x, ox) - min(x + w, ox + ow))
        if vertical > min(h, oh) * 0.45 and gap < max(h, oh) * 0.9:
            candidates.append(other)
    if not candidates:
        return word
    other = min(candidates, key=lambda item: abs(item.center[0] - word.center[0]))
    x0 = min(word.box[0], other.box[0])
    y0 = min(word.box[1], other.box[1])
    x1 = max(word.box[0] + word.box[2], other.box[0] + other.box[2])
    y1 = max(word.box[1] + word.box[3], other.box[1] + other.box[3])
    return OcrWord(word.index, word.text + other.text, word.confidence, (x0, y0, x1 - x0, y1 - y0))


def _room_labels(
    rooms: list[RoomGeometry], known_numbers: set[str], words: list[OcrWord], used: set[int]
) -> list[TextLabel]:
    labels = []
    number_height = _median_number_height(words)
    for room in rooms:
        anchor_x, anchor_y = room.anchor
        x, y, w, h = cv2.boundingRect(room.polygon.astype(np.int32))
        font_size = min(
            number_height * 1.05,
            w / max(len(room.number) * 0.72, 1),
            h * 0.32,
        )
        if font_size < 5:
            continue
        text_width = len(room.number) * font_size * 0.68
        box = (
            anchor_x - text_width / 2,
            anchor_y - font_size * 0.65,
            text_width,
            font_size * 1.3,
        )
        mask_boxes = [box]
        normalized_number = _normalize_label(room.number)
        for word in words:
            if word.index in used or not _point_inside(room.polygon, word.center):
                continue
            if not number_height * 0.55 <= word.box[3] <= number_height * 1.7:
                continue
            normalized_word = _normalize_label(word.text)
            has_number = bool(re.search(r"\d", normalized_word))
            is_suffix = (
                normalized_word.isalpha()
                and len(normalized_word) <= 3
                and normalized_number.endswith(normalized_word)
            )
            if not has_number and not is_suffix:
                continue
            used.add(word.index)
            mask_boxes.append(word.box)
        x0 = min(item[0] for item in mask_boxes)
        y0 = min(item[1] for item in mask_boxes)
        x1 = max(item[0] + item[2] for item in mask_boxes)
        y1 = max(item[1] + item[3] for item in mask_boxes)
        inset = 3
        x0, y0 = max(x0, x + inset), max(y0, y + inset)
        x1, y1 = min(x1, x + w - inset), min(y1, y + h - inset)
        if x1 <= x0 or y1 <= y0:
            x0, y0, w0, h0 = box
            x1, y1 = x0 + w0, y0 + h0
        labels.append(
            TextLabel(
                room.number,
                box,
                font_size,
                mask_box=(x0, y0, x1 - x0, y1 - y0),
            )
        )
    return labels


def _extra_ocr_labels(
    words: list[OcrWord], known_numbers: set[str], used: set[int], title_height: float
) -> list[TextLabel]:
    labels = []
    for word in words:
        normalized = _normalize_label(word.text)
        if word.index in used or word.confidence < 45 or not re.search(r"\d", normalized):
            continue
        if not re.fullmatch(r"[0-9A-Z-]{2,10}", normalized):
            continue
        if normalized not in known_numbers and not (
            word.confidence >= 75 and len(normalized) >= 3
        ):
            continue
        x, y, w, h = word.box
        if not title_height * 0.55 <= h <= title_height * 1.8:
            continue
        used.add(word.index)
        pad = max(1.0, h * 0.1)
        labels.append(TextLabel(word.text, (x - pad, y - pad, w + 2 * pad, h + 2 * pad), h * 1.05))
    return labels


def _mask_label(image: np.ndarray, label: TextLabel) -> None:
    x, y, w, h = label.mask_box or label.box
    pad_x = max(1.0, label.font_size * 0.35)
    pad_y = max(1.0, label.font_size * 1.5)
    cv2.rectangle(
        image,
        (math.floor(x - pad_x), math.floor(y - pad_y)),
        (math.ceil(x + w + pad_x), math.ceil(y + h + pad_y)),
        (255, 255, 255),
        -1,
    )


def _fit_circle(points: np.ndarray) -> tuple[float, float, float, float] | None:
    xy = points.astype(np.float64)
    if len(xy) < 10:
        return None
    matrix = np.column_stack((2 * xy[:, 0], 2 * xy[:, 1], np.ones(len(xy))))
    target = np.sum(xy * xy, axis=1)
    try:
        cx, cy, constant = np.linalg.lstsq(matrix, target, rcond=None)[0]
    except np.linalg.LinAlgError:
        return None
    squared = constant + cx * cx + cy * cy
    if squared <= 0:
        return None
    radius = math.sqrt(squared)
    distances = np.hypot(xy[:, 0] - cx, xy[:, 1] - cy)
    residual = float(np.sqrt(np.mean((distances - radius) ** 2)))
    return float(cx), float(cy), float(radius), residual


def _arc_angles(points: np.ndarray, cx: float, cy: float) -> tuple[float, float] | None:
    angles = np.sort(np.arctan2(points[:, 1] - cy, points[:, 0] - cx) % (2 * math.pi))
    if len(angles) < 2:
        return None
    gaps = np.diff(np.concatenate((angles, [angles[0] + 2 * math.pi])))
    index = int(np.argmax(gaps))
    start = float(angles[(index + 1) % len(angles)])
    end = float(angles[index])
    coverage = (end - start) % (2 * math.pi)
    return start, start + coverage


def _radial_score(binary: np.ndarray, cx: float, cy: float, radius: float, angle: float) -> float:
    hits = 0
    samples = 24
    height, width = binary.shape
    for t in np.linspace(0.12, 1.03, samples):
        x = round(cx + radius * t * math.cos(angle))
        y = round(cy + radius * t * math.sin(angle))
        if x < 1 or y < 1 or x >= width - 1 or y >= height - 1:
            continue
        hits += int(binary[y - 1 : y + 2, x - 1 : x + 2].any())
    return hits / samples


def _boundary_distance(polygon: np.ndarray, point: tuple[float, float]) -> float:
    return abs(cv2.pointPolygonTest(polygon, point, True))


def _point_segment_distance(point: np.ndarray, start: np.ndarray, end: np.ndarray) -> float:
    vector = end - start
    length_squared = float(np.dot(vector, vector))
    if length_squared <= 1e-6:
        return float(np.linalg.norm(point - start))
    t = float(np.clip(np.dot(point - start, vector) / length_squared, 0, 1))
    return float(np.linalg.norm(point - (start + vector * t)))


def _shares_room_edge(
    first: np.ndarray, second: np.ndarray, polygons: list[np.ndarray], tolerance: float
) -> bool:
    if not polygons:
        return True
    for polygon in polygons:
        for index in range(len(polygon)):
            start, end = polygon[index], polygon[(index + 1) % len(polygon)]
            if (
                _point_segment_distance(first, start, end) <= tolerance
                and _point_segment_distance(second, start, end) <= tolerance
            ):
                return True
    return False


def _positive_arc(start: float, end: float) -> tuple[float, float]:
    coverage = (end - start) % (2 * math.pi)
    if coverage > math.pi:
        start, end = end, start
        coverage = (end - start) % (2 * math.pi)
    return start, start + coverage


def _wall_evidence(binary: np.ndarray, first: np.ndarray, second: np.ndarray) -> bool:
    vector = second - first
    opening = float(np.linalg.norm(vector))
    if opening < 1:
        return False
    direction = vector / opening
    height, width = binary.shape

    def score(origin: np.ndarray, sign: float) -> float:
        hits = 0
        samples = 9
        for t in np.linspace(0.15, 0.85, samples):
            point = origin + direction * (opening * t * sign)
            x, y = round(float(point[0])), round(float(point[1]))
            if x < 2 or y < 2 or x >= width - 2 or y >= height - 2:
                continue
            hits += int(binary[y - 2 : y + 3, x - 2 : x + 3].any())
        return hits / samples

    first_score = score(first, -1)
    second_score = score(second, 1)
    return min(first_score, second_score) >= 0.15 and (first_score + second_score) / 2 >= 0.3


def _detect_doors(image: np.ndarray, rooms: list[RoomGeometry]) -> list[DoorSymbol]:
    height, width = image.shape[:2]
    scale = min(1.0, 2200 / max(width, height))
    small = cv2.resize(image, (round(width * scale), round(height * scale))) if scale < 1 else image.copy()
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    binary = (gray < 205).astype(np.uint8)
    line_length = max(13, round(max(small.shape[:2]) * 0.009))
    horizontal = cv2.morphologyEx(binary, cv2.MORPH_OPEN, np.ones((1, line_length), np.uint8))
    vertical = cv2.morphologyEx(binary, cv2.MORPH_OPEN, np.ones((line_length, 1), np.uint8))
    straight = cv2.dilate(cv2.bitwise_or(horizontal, vertical), np.ones((3, 3), np.uint8))
    curves = cv2.bitwise_and(binary, 1 - straight)
    curves = cv2.morphologyEx(curves, cv2.MORPH_CLOSE, np.ones((2, 2), np.uint8))
    contours, _ = cv2.findContours(curves, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    room_polygons = [(room.polygon * scale).astype(np.float32) for room in rooms]
    candidates = []
    for contour in contours:
        points = contour.reshape(-1, 2).astype(np.float64)
        if len(points) < 12:
            continue
        x, y, w, h = cv2.boundingRect(contour)
        if min(w, h) < 7 or max(w, h) > min(small.shape[:2]) * 0.25:
            continue
        fitted = _fit_circle(points)
        if fitted is None:
            continue
        cx, cy, radius, residual = fitted
        if not 7 <= radius <= min(small.shape[:2]) * 0.18 or residual > radius * 0.16:
            continue
        if max(w, h) > radius * 2.5 or max(w, h) < radius * 0.55:
            continue
        angles = _arc_angles(points, cx, cy)
        if angles is None:
            continue
        start, end = angles
        coverage = end - start
        if not math.radians(42) <= coverage <= math.radians(205):
            continue
        boundary = min(
            (_boundary_distance(polygon, (cx, cy)) for polygon in room_polygons),
            default=radius,
        )
        if room_polygons and boundary > max(4, radius * 0.48):
            continue
        scores = [_radial_score(binary, cx, cy, radius, angle) for angle in (start, end)]
        leaf_index = int(scores[1] > scores[0])
        leaf_score = scores[leaf_index]
        if leaf_score < 0.38:
            continue
        score = leaf_score + coverage / math.pi - residual / max(radius, 1)
        candidates.append((score, cx, cy, radius, start, end, (start, end)[leaf_index], points))
    edges = cv2.Canny(gray, 30, 100)
    raw_lines = cv2.HoughLinesP(
        edges,
        1,
        np.pi / 360,
        threshold=6,
        minLineLength=7,
        maxLineGap=3,
    )
    segments = []
    if raw_lines is not None:
        for x1, y1, x2, y2 in raw_lines.reshape(-1, 4):
            first = np.array([float(x1), float(y1)])
            second = np.array([float(x2), float(y2)])
            vector = second - first
            length = float(np.linalg.norm(vector))
            if not 7 <= length <= min(small.shape[:2]) * 0.18:
                continue
            angle = abs(math.atan2(float(vector[1]), float(vector[0]))) % math.pi
            diagonal = min(angle, abs(angle - math.pi / 2), abs(angle - math.pi))
            is_diagonal = diagonal >= math.radians(12)
            if not is_diagonal and length > 60:
                continue
            midpoint = (first + second) / 2
            if room_polygons:
                boundary = min(
                    _boundary_distance(polygon, (float(midpoint[0]), float(midpoint[1])))
                    for polygon in room_polygons
                )
                if boundary > max(10, length * 0.8):
                    continue
            segments.append((first, second, length, is_diagonal))
    for index, (first, second, first_length, first_diagonal) in enumerate(segments):
        for other_first, other_second, second_length, second_diagonal in segments[index + 1 :]:
            if not first_diagonal and not second_diagonal:
                continue
            for apex_first, first_end in ((0, first), (1, second)):
                for apex_second, second_end in ((0, other_first), (1, other_second)):
                    apex_distance = float(np.linalg.norm(first_end - second_end))
                    if apex_distance > max(6.0, min(first_length, second_length) * 0.45):
                        continue
                    apex = (first_end + second_end) / 2
                    first_outer = second if apex_first == 0 else first
                    second_outer = other_second if apex_second == 0 else other_first
                    side_one = float(np.linalg.norm(first_outer - apex))
                    side_two = float(np.linalg.norm(second_outer - apex))
                    opening = float(np.linalg.norm(second_outer - first_outer))
                    min_opening = max(12, min(small.shape[:2]) * 0.012)
                    if opening < min_opening or min(side_one, side_two) < 6:
                        continue
                    if not 0.55 <= opening / max((side_one + side_two) / 2, 1) <= 2.5:
                        continue
                    vectors = [first_outer - apex, second_outer - apex]
                    cosine = float(np.dot(vectors[0], vectors[1]) / max(side_one * side_two, 1))
                    apex_angle = math.acos(float(np.clip(cosine, -1, 1)))
                    if not math.radians(42) <= apex_angle <= math.radians(138):
                        continue
                    tolerance = max(4.0, opening * 0.12)
                    if not _shares_room_edge(
                        first_outer, second_outer, room_polygons, tolerance
                    ) and not _wall_evidence(binary, first_outer, second_outer):
                        continue
                    best = None
                    for hinge, jamb in ((first_outer, second_outer), (second_outer, first_outer)):
                        leaf_angle = math.atan2(float(apex[1] - hinge[1]), float(apex[0] - hinge[0]))
                        jamb_angle = math.atan2(float(jamb[1] - hinge[1]), float(jamb[0] - hinge[0]))
                        delta = (jamb_angle - leaf_angle + math.pi) % (2 * math.pi) - math.pi
                        if not math.radians(32) <= abs(delta) <= math.radians(142):
                            continue
                        start, end = _positive_arc(leaf_angle, jamb_angle)
                        score = 2.4 - abs(abs(delta) - math.pi / 2) / math.pi
                        score -= abs(side_one - side_two) / max(side_one, side_two) * 0.2
                        if not first_diagonal or not second_diagonal:
                            score -= 0.18
                        if best is None or score > best[0]:
                            best = (score, hinge, start, end, leaf_angle)
                    if best is not None:
                        score, hinge, start, end, leaf_angle = best
                        candidates.append(
                            (
                                score,
                                float(hinge[0]),
                                float(hinge[1]),
                                opening,
                                start,
                                end,
                                leaf_angle,
                                np.asarray([first_outer, apex, second_outer]),
                            )
                        )
    candidates.sort(key=lambda item: item[0], reverse=True)
    kept = []
    min_radius = max(16, min(small.shape[:2]) * 0.016)
    max_radius = min(small.shape[:2]) * 0.045

    def region_center(candidate) -> np.ndarray:
        points = candidate[7]
        return (np.min(points, axis=0) + np.max(points, axis=0)) / 2

    for candidate in candidates:
        score, cx, cy, radius = candidate[:4]
        if score < 2.05 or not min_radius <= radius <= max_radius:
            continue
        center = region_center(candidate)
        duplicate = False
        for other in kept:
            same_hinge = (
                math.hypot(cx - other[1], cy - other[2]) < max(radius, other[3]) * 0.45
                and abs(radius - other[3]) < max(radius, other[3]) * 0.4
            )
            other_center = region_center(other)
            same_region = (
                float(np.linalg.norm(center - other_center)) < max(radius, other[3]) * 0.4
                and abs(radius - other[3]) < max(radius, other[3]) * 0.65
            )
            if same_hinge or same_region:
                duplicate = True
                break
        if not duplicate:
            kept.append(candidate)
    doors = []
    for score, cx, cy, radius, start, end, leaf, points in kept:
        doors.append(
            DoorSymbol(
                cx / scale,
                cy / scale,
                radius / scale,
                start,
                end,
                leaf,
                (points / scale).astype(np.int32),
                score,
            )
        )
    return doors


def _mask_door(image: np.ndarray, door: DoorSymbol) -> None:
    thickness = max(3, round(door.radius * 0.1))
    points = np.linspace(door.start_angle, door.end_angle, 48)
    arc = np.asarray(
        [
            [
                round(door.cx + door.radius * math.cos(angle)),
                round(door.cy + door.radius * math.sin(angle)),
            ]
            for angle in points
        ],
        dtype=np.int32,
    )
    leaf = door._point(door.leaf_angle)
    cv2.polylines(image, [arc], False, (255, 255, 255), thickness)
    cv2.polylines(image, [door.source_points.reshape(-1, 1, 2)], False, (255, 255, 255), thickness)
    cv2.line(
        image,
        (round(door.cx), round(door.cy)),
        (round(leaf[0]), round(leaf[1])),
        (255, 255, 255),
        thickness,
    )


def build_detail_layer(
    image_path: Path, detail_path: Path | None, building: str, floor: str
) -> DetailLayer:
    with Image.open(image_path) as source:
        rgb = source.convert("RGB")
        original = np.asarray(rgb, dtype=np.uint8).copy()
        detail = _load_json(detail_path)
        warnings: list[str] = []
        title_words = _ocr(rgb, warnings, psm=6)
        room_words = _ocr(rgb, warnings, psm=11)
        rooms, known_numbers, _ = _rooms_and_numbers(detail, rgb.size)
        title, _ = _title_label(title_words, rgb.size, generated_title(building, floor))
        used: set[int] = set()
        labels = _room_labels(rooms, known_numbers, room_words, used)
        labels.extend(
            _extra_ocr_labels(
                room_words, known_numbers, used, _median_number_height(room_words)
            )
        )
        if title is not None:
            labels.append(title)
        masked = original.copy()
        for label in labels:
            _mask_label(masked, label)
        doors = _detect_doors(masked, rooms)
        for door in doors:
            _mask_door(masked, door)
        return DetailLayer(masked, labels, doors, warnings)
