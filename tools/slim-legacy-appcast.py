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
_ITEM_BLOCK = re.compile(
    r"<item\b" + _TAG_ATTRIBUTES + r">"
    r"(?:(?:" + _CDATA + r")|(?:(?!</item\s*>)[\s\S]))*"
    r"</item\s*>",
)
_DESCRIPTION_CORE = (
    r"<description\b"
    + _TAG_ATTRIBUTES
    + r">[ \t\r\n]*"
    + _CDATA
    + r"[ \t\r\n]*</description\s*>"
)
_ITEM_CDATA_DESCRIPTION = re.compile(
    r"(?:(?:(?<=\n)|\A)[ \t]*"
    + _DESCRIPTION_CORE
    + r"[ \t]*(?:\r\n|\n|\r)?|"
    + _DESCRIPTION_CORE
    + r")"
)


def _validate_xml(payload, label):
    if not isinstance(payload, str):
        raise SlimFeedError("{} must be Unicode text".format(label))
    try:
        ElementTree.fromstring(payload)
    except (ElementTree.ParseError, ValueError) as error:
        raise SlimFeedError("{} XML is malformed: {}".format(label, error)) from None


def slim_feed(payload: str) -> str:
    """Remove only CDATA description elements contained by item blocks."""

    _validate_xml(payload, "input")

    def slim_item(match):
        return _ITEM_CDATA_DESCRIPTION.sub("", match.group(0))

    slimmed = _ITEM_BLOCK.sub(slim_item, payload)
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
