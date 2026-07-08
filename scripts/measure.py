#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "rich",
# ]
# ///

import argparse
import csv
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from rich import print


def parse_oavif_output(stderr_output: str) -> Optional[int]:
    """
    Parse oavif stderr output to extract passes information.
    Accepts lines like '2 passes' or '1 pass'.
    """
    passes_match = re.search(r"(\d+)\s+passes?", stderr_output, re.IGNORECASE)
    return int(passes_match.group(1)) if passes_match else None


def human_bytes(n: int) -> str:
    """Return a human-friendly byte string."""
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(n)
    for u in units:
        if size < 1024.0 or u == units[-1]:
            return f"{size:.2f} {u}"
        size /= 1024.0


def process_image(
    oavif_path: str,
    image_path: Path,
    output_dir: Path,
    tolerance: Optional[float] = None,
) -> Dict[str, Any]:
    """
    Process a single image with oavif and return metrics.
    Returns a dict with keys:
      - image, encoding_time_ms, passes, orig_bytes, final_bytes, savings_bytes, savings_pct, status, error
    """
    image_name = image_path.name
    avif_output = output_dir / f"{image_path.stem}.avif"
    orig_bytes = image_path.stat().st_size

    cmd: list[str] = [oavif_path]
    if tolerance is not None:
        cmd.extend(["--tolerance", str(tolerance)])
    cmd.extend([str(image_path), str(avif_output)])

    start_time = time.perf_counter()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        encoding_time_ms = (time.perf_counter() - start_time) * 1000.0

        stderr_output = result.stderr or ""
        passes = parse_oavif_output(stderr_output)

        # Ensure output exists (encoder may succeed but not write if skipped)
        if avif_output.exists():
            final_bytes = avif_output.stat().st_size
        else:
            final_bytes = None

        if final_bytes is None or orig_bytes == 0:
            savings_bytes = None
            savings_pct = None
        else:
            savings_bytes = max(orig_bytes - final_bytes, 0)
            savings_pct = (savings_bytes / orig_bytes) * 100.0

        return {
            "image": image_name,
            "encoding_time_ms": encoding_time_ms,
            "passes": passes,
            "orig_bytes": orig_bytes,
            "final_bytes": final_bytes,
            "savings_bytes": savings_bytes,
            "savings_pct": savings_pct,
            "status": "ok" if final_bytes is not None else "no-output",
            "error": None,
            "stderr": stderr_output.strip(),
        }
    except subprocess.CalledProcessError as e:
        _ = (
            time.perf_counter() - start_time
        ) * 1000.0  # still measure elapsed, but we report None
        return {
            "image": image_name,
            "encoding_time_ms": None,
            "passes": None,
            "orig_bytes": orig_bytes,
            "final_bytes": None,
            "savings_bytes": None,
            "savings_pct": None,
            "status": "error",
            "error": f"Error processing {image_path}: {e}",
            "stderr": (e.stderr or "").strip() if hasattr(e, "stderr") else "",
        }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Measure oavif performance on a directory of images"
    )
    parser.add_argument("images_dir", help="Directory containing input images")
    parser.add_argument("oavif_path", help="Path to oavif binary")
    parser.add_argument("output_csv", help="Output CSV file path")
    parser.add_argument(
        "--tolerance", type=float, help="Tolerance value for oavif encoding"
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="Keep generated .avif files (default: delete after run)",
    )
    args = parser.parse_args()

    if not Path(args.oavif_path).exists():
        print(f"[red]Error: oavif binary not found at {args.oavif_path}[/red]")
        sys.exit(1)

    images_dir = Path(args.images_dir)
    if not images_dir.exists():
        print(f"[red]Error: images directory not found at {images_dir}[/red]")
        sys.exit(1)

    temp_output_dir = Path("temp_avif_output")
    temp_output_dir.mkdir(exist_ok=True)

    image_extensions: set[str] = {".png"}
    image_files: list[Path] = sorted(
        f
        for f in images_dir.iterdir()
        if f.is_file() and f.suffix.lower() in image_extensions
    )

    if not image_files:
        print(f"[yellow]No images found in {images_dir}[/yellow]")
        sys.exit(1)

    results: List[Dict[str, Any]] = []

    print(f"[cyan]Found {len(image_files)} images. Starting encoding...[/cyan]")
    wall_start = time.perf_counter()

    for image_file in image_files:
        print(f"Processing {image_file.name}...")
        metrics = process_image(
            args.oavif_path, image_file, temp_output_dir, args.tolerance
        )
        if metrics["status"] == "error":
            print(f"[red]{metrics['error']}[/red]")
        elif metrics["status"] == "no-output":
            print(f"[yellow]No output produced for {image_file.name}[/yellow]")
        results.append(metrics)

    wall_elapsed_s = time.perf_counter() - wall_start

    # Optionally clean up generated AVIFs
    if not args.keep:
        for m in results:
            out = temp_output_dir / f"{Path(m['image']).stem}.avif"
            try:
                if out.exists():
                    out.unlink()
            except Exception:
                pass
        # Remove the temp dir if empty
        try:
            temp_output_dir.rmdir()
        except OSError:
            pass

    # Write CSV with expanded metrics
    with open(args.output_csv, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(
            [
                "Image",
                "Original Bytes",
                "Final Bytes",
                "Savings Bytes",
                "Savings %",
                "Encoding Time (ms)",
                "Passes",
                "Status",
                "Error",
            ]
        )
        for m in results:
            writer.writerow(
                [
                    m["image"],
                    m["orig_bytes"],
                    m["final_bytes"] if m["final_bytes"] is not None else "",
                    m["savings_bytes"] if m["savings_bytes"] is not None else "",
                    f"{m['savings_pct']:.2f}" if m["savings_pct"] is not None else "",
                    f"{m['encoding_time_ms']:.2f}"
                    if m["encoding_time_ms"] is not None
                    else "",
                    m["passes"] if m["passes"] is not None else "",
                    m["status"],
                    m["error"] or "",
                ]
            )

    # Aggregate statistics
    ok = [m for m in results if m["status"] == "ok"]
    errors = [m for m in results if m["status"] == "error"]
    no_out = [m for m in results if m["status"] == "no-output"]

    def safe_geomean(ratios: List[float]) -> Optional[float]:
        try:
            return statistics.geometric_mean(ratios) if ratios else None
        except ValueError:
            return None

    encoding_times = [
        m["encoding_time_ms"] for m in ok if m["encoding_time_ms"] is not None
    ]
    passes_list = [m["passes"] for m in ok if m["passes"] is not None]
    orig_total = sum(m["orig_bytes"] for m in ok)
    final_total = sum(m["final_bytes"] for m in ok if m["final_bytes"] is not None)
    savings_total = max(orig_total - final_total, 0) if ok else 0
    pct_saved_overall = (savings_total / orig_total) * 100.0 if orig_total > 0 else 0.0

    ratios = [
        (m["final_bytes"] / m["orig_bytes"])
        for m in ok
        if m["final_bytes"] is not None and m["orig_bytes"] > 0
    ]
    geomean_ratio = safe_geomean(ratios)
    geomean_savings_pct = (
        (1.0 - geomean_ratio) * 100.0 if geomean_ratio is not None else None
    )

    # Throughput metrics
    img_throughput = (len(ok) / wall_elapsed_s) if wall_elapsed_s > 0 else 0.0
    byte_in_throughput = (orig_total / wall_elapsed_s) if wall_elapsed_s > 0 else 0.0
    byte_out_throughput = (final_total / wall_elapsed_s) if wall_elapsed_s > 0 else 0.0

    # Dispersion
    avg_encoding_time = (
        (sum(encoding_times) / len(encoding_times)) if encoding_times else 0.0
    )
    median_encoding_time = statistics.median(encoding_times) if encoding_times else 0.0
    encoding_time_stddev = (
        statistics.stdev(encoding_times) if len(encoding_times) > 1 else 0.0
    )

    avg_passes = (sum(passes_list) / len(passes_list)) if passes_list else 0.0
    max_passes = max(passes_list) if passes_list else 0
    min_passes = min(passes_list) if passes_list else 0
    passes_stddev = statistics.stdev(passes_list) if len(passes_list) > 1 else 0.0

    # Summary printout
    print("\n[bold]Run Summary[/bold]")
    print(
        f"Images: [green]{len(ok)} ok[/green], [yellow]{len(no_out)} no-output[/yellow], [red]{len(errors)} errors[/red]"
    )
    print(f"Total wall time: {wall_elapsed_s:.2f} s")
    print(f"Throughput: {img_throughput:.2f} images/s")
    print(f"Input bytes throughput: {human_bytes(int(byte_in_throughput))}/s")
    print(f"Output bytes throughput: {human_bytes(int(byte_out_throughput))}/s")

    print("\n[bold]Compression Totals[/bold]")
    print(f"Original total bytes: {orig_total} ({human_bytes(orig_total)})")
    print(f"Final total bytes:    {final_total} ({human_bytes(final_total)})")
    print(f"Savings (bytes):      {savings_total} ({human_bytes(savings_total)})")
    print(f"% saved (overall):    {pct_saved_overall:.2f}%")
    if geomean_savings_pct is not None:
        print(f"% saved (geometric mean across files): {geomean_savings_pct:.2f}%")

    if encoding_times:
        print("\n[bold]Timing & Passes[/bold]")
        print(
            f"Average encoding time: {avg_encoding_time:.2f} ms ± {encoding_time_stddev:.2f}"
        )
        print(f"Median encoding time:  {median_encoding_time:.2f} ms")
        print(
            f"Average passes:        {avg_passes:.2f} ± {passes_stddev:.2f} (max: {max_passes}, min: {min_passes})"
        )

    print(f"\nResults written to [bold]{args.output_csv}[/bold]")


if __name__ == "__main__":
    main()
