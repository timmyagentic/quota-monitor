#!/usr/bin/env python3
"""Surgically remove legacy item CDATA descriptions from an Appcast."""

import argparse
import os
import pathlib
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as ElementTree


class SlimFeedError(Exception):
    """Expected input, transformation, or output failure."""


_TAG_ATTRIBUTES = r'''(?:[^>"']|"[^"]*"|'[^']*')*'''
_CDATA = r"<!\[CDATA\[(?:(?!\]\]>)[\s\S])*\]\]>"
_ITEM_TAG = re.compile(
    r"<item\b" + _TAG_ATTRIBUTES + r">|</item\s*>"
)
_DESCRIPTION_CORE = (
    r"<description\b"
    + _TAG_ATTRIBUTES
    + r">[ \t\r\n]*"
    + _CDATA
    + r"[ \t\r\n]*</description\s*>"
)
_ITEM_CDATA_DESCRIPTION = re.compile(_DESCRIPTION_CORE)
_COMMENT_OPEN = "<!--"
_COMMENT_CLOSE = "-->"
_CDATA_OPEN = "<![CDATA["
_CDATA_CLOSE = "]]>"
_PI_OPEN = "<?"
_PI_CLOSE = "?>"


def _validate_xml(payload, label):
    if not isinstance(payload, str):
        raise SlimFeedError("{} must be Unicode text".format(label))
    try:
        ElementTree.fromstring(payload)
    except (ElementTree.ParseError, ValueError) as error:
        raise SlimFeedError("{} XML is malformed: {}".format(label, error)) from None


def _mask_range(characters, start, end):
    for index in range(start, end):
        characters[index] = "\0"


def _protected_masks(payload):
    item_mask = list(payload)
    description_mask = list(payload)
    index = 0
    while index < len(payload):
        if payload.startswith(_COMMENT_OPEN, index):
            close = payload.find(_COMMENT_CLOSE, index + len(_COMMENT_OPEN))
            end = close + len(_COMMENT_CLOSE)
            _mask_range(item_mask, index, end)
            _mask_range(description_mask, index, end)
        elif payload.startswith(_CDATA_OPEN, index):
            content_start = index + len(_CDATA_OPEN)
            content_end = payload.find(_CDATA_CLOSE, content_start)
            end = content_end + len(_CDATA_CLOSE)
            _mask_range(item_mask, index, end)
            _mask_range(description_mask, content_start, content_end)
        elif payload.startswith(_PI_OPEN, index):
            close = payload.find(_PI_CLOSE, index + len(_PI_OPEN))
            end = close + len(_PI_CLOSE)
            _mask_range(item_mask, index, end)
            _mask_range(description_mask, index, end)
        else:
            index += 1
            continue
        index = end
    return "".join(item_mask), "".join(description_mask)


def _item_spans(item_mask):
    spans = []
    depth = 0
    outer_start = None
    for match in _ITEM_TAG.finditer(item_mask):
        tag = match.group(0)
        if tag.startswith("</"):
            if depth == 0:
                continue
            depth -= 1
            if depth == 0:
                spans.append((outer_start, match.end()))
                outer_start = None
        elif not tag.rstrip().endswith("/>"):
            if depth == 0:
                outer_start = match.start()
            depth += 1
    return spans


def _line_removal_span(payload, start, end, item_start):
    previous_newline = max(
        payload.rfind("\n", item_start, start),
        payload.rfind("\r", item_start, start),
    )
    line_start = previous_newline + 1
    if payload[line_start:start].strip(" \t"):
        return start, end

    trailing = re.match(r"[ \t]*(?:\r\n|\n|\r)?", payload[end:])
    return line_start, end + len(trailing.group(0))


def _description_removals(payload, description_mask, item_spans):
    removals = []
    for item_start, item_end in item_spans:
        masked_item = description_mask[item_start:item_end]
        for match in _ITEM_CDATA_DESCRIPTION.finditer(masked_item):
            start = item_start + match.start()
            end = item_start + match.end()
            removals.append(_line_removal_span(payload, start, end, item_start))
    return removals


def _remove_spans(payload, spans):
    pieces = []
    cursor = 0
    for start, end in spans:
        pieces.append(payload[cursor:start])
        cursor = end
    pieces.append(payload[cursor:])
    return "".join(pieces)


def slim_feed(payload: str) -> str:
    """Remove only CDATA description elements contained by item blocks."""

    _validate_xml(payload, "input")
    item_mask, description_mask = _protected_masks(payload)
    item_spans = _item_spans(item_mask)
    removals = _description_removals(payload, description_mask, item_spans)
    slimmed = _remove_spans(payload, removals)
    _validate_xml(slimmed, "output")
    return slimmed


def _same_path(first, second):
    try:
        return os.path.samefile(str(first), str(second))
    except (FileNotFoundError, OSError):
        return first.resolve(strict=False) == second.resolve(strict=False)


def _atomic_write(destination, payload, mode):
    destination = pathlib.Path(destination)
    file_descriptor = None
    temporary_path = None
    try:
        file_descriptor, temporary_name = tempfile.mkstemp(
            prefix=".{}-".format(destination.name),
            suffix=".tmp",
            dir=str(destination.parent),
        )
        temporary_path = pathlib.Path(temporary_name)
        handle = os.fdopen(file_descriptor, "wb")
        file_descriptor = None
        with handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(str(temporary_path), mode)
        os.replace(str(temporary_path), str(destination))
        temporary_path = None
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def _argument_parser():
    parser = argparse.ArgumentParser(
        description="Remove legacy item CDATA descriptions from an Appcast"
    )
    parser.add_argument("input", metavar="INPUT")
    parser.add_argument("output", nargs="?", metavar="OUTPUT")
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="atomically replace INPUT; OUTPUT may only name the same path",
    )
    return parser


def _single_line(value):
    return " ".join(str(value).splitlines())


def main(argv=None, stdout=None, stderr=None):
    arguments = _argument_parser().parse_args(argv)
    output_stream = sys.stdout if stdout is None else stdout
    error_stream = sys.stderr if stderr is None else stderr
    source = pathlib.Path(arguments.input)
    requested_output = (
        pathlib.Path(arguments.output) if arguments.output is not None else None
    )

    try:
        if arguments.in_place:
            if requested_output is not None and not _same_path(source, requested_output):
                raise SlimFeedError(
                    "--in-place may not be combined with a different output path"
                )
            destination = source
        else:
            if requested_output is not None and _same_path(source, requested_output):
                raise SlimFeedError(
                    "refusing to overwrite the input without --in-place"
                )
            destination = requested_output

        source_bytes = source.read_bytes()
        source_mode = stat.S_IMODE(source.stat().st_mode)
        try:
            source_text = source_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            raise SlimFeedError("input is not valid UTF-8: {}".format(error)) from None

        slimmed = slim_feed(source_text)
        slimmed_bytes = slimmed.encode("utf-8")
        if destination is None:
            output_stream.write(slimmed)
        else:
            _atomic_write(destination, slimmed_bytes, source_mode)
    except (SlimFeedError, OSError) as error:
        error_stream.write("error: {}\n".format(_single_line(error)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
