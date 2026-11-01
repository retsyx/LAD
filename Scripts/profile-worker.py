#!/usr/bin/env python3
"""Profile a retained ProjectOpeningProfileTests build using LAD's bundled Python.

Usage: <managed-python> Scripts/profile-worker.py /tmp/lad-opening-<id>
All outputs stay in that temporary build directory. Timings are nested, not additive.
"""
import argparse
import cProfile
import importlib.util
import json
from pathlib import Path
import pstats
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_directory', type=Path)
    args = parser.parse_args()
    folder = args.build_directory.resolve()
    if not (folder / 'request.json').is_file():
        parser.error('build_directory must contain the retained request.json and its inputs')
    output = folder / 'profile-output'
    if output.exists():
        parser.error('profile-output already exists; use a fresh copy of the build directory')
    times = {}
    start = time.perf_counter()
    import cadquery  # noqa: F401 -- measure the import excluded by buildSeconds
    times['cadqueryImport'] = time.perf_counter() - start
    spec = importlib.util.spec_from_file_location('worker', Path(__file__).resolve().parents[1] / 'Engine/worker.py')
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    for name in ('build_shape', 'build_script', 'import_step', 'validate_shape', 'write_step',
                 'validate_step_roundtrip', 'make_preview', 'write_brep'):
        original = getattr(worker, name)

        def timed(*a, _fn=original, _name=name, **kw):
            started = time.perf_counter()
            try:
                return _fn(*a, **kw)
            finally:
                times.setdefault(_name, []).append(time.perf_counter() - started)

        setattr(worker, name, timed)
    profile = cProfile.Profile()
    start = time.perf_counter()
    profile.enable()
    worker.run(folder / 'request.json', output, 8, True)
    profile.disable()
    times['workerTotalAfterImport'] = time.perf_counter() - start
    profile.dump_stats(str(folder / 'worker.pstats'))
    (folder / 'worker-stages.json').write_text(json.dumps(times, indent=2))
    pstats.Stats(profile).strip_dirs().sort_stats('tottime').print_stats(40)
    print(json.dumps(times, indent=2))


if __name__ == '__main__':
    main()
