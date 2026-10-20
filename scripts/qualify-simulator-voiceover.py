#!/usr/bin/env python3
"""Assert cursor activation workflows on fresh Pro, Pro Max and iPad simulators at two text sizes.

Includes the immediate link-target announcement regression from #495. Requires the Xcode
whose SDK matches the pinned runtime. Stops on any failed assertion,
missing action, missing hook/canary, timeout, lost mute or cleanup failure. Results are
local; publish a concise result on #495 before changing qualification or acceptance policy.
"""
import argparse
from pathlib import Path
import subprocess
import signal
import sys
import simulator_voiceover_activation as activation


def workflows(size):
    steps = []
    for orientation in ('portrait', 'landscape'):
        steps += [f'rotate={orientation}', f'fresh=paginated:{size}:OPS/body.xhtml:none',
                  'touch=Page boundary', 'keyrotor=Actions', 'chooseup=Next Page',
                  'mark=first', 'doublepoint=0.5:0.2', 'changed=first', 'visible', 'forward=1', 'focusvisible',
                  'touch=word', 'keyrotor=Actions', 'chooseup=Previous Page',
                  'doublepoint=0.5:0.2', 'same=first',
                  f'fresh=paginated:{size}:OPS/body.xhtml#activation-link:none',
                  'touch=Verification link', 'doublepoint=0.5:0.2', 'expect=Link target reached',
                  'forward=1', 'expect=This is the end', 'backward=1', 'expect=Link target reached',
                  f'fresh=paginated:{size}:OPS/body.xhtml#verification-image:none',
                  'touch=Blue verification square', 'keyrotor=Actions', 'chooseup=Inspect Image',
                  'doublepoint=0.5:0.2', 'exists=Zoom In', 'exists=Magnification', 'forward=1', 'expect=Zoom In',
                  f'fresh=paginated:{size}:OPS/grids.xhtml#activation-cell:none',
                  'touch=Alder', 'keyrotor=Actions', 'chooseup=Select Cell Text',
                  'doublepoint=0.5:0.2', 'expectstate=Selected: Alder. Used: nothing.',
                  'chooseup=Use passage', 'doublepoint=0.5:0.2', 'expectstate=Selected: Alder. Used: Alder.',
                  'chooseup=Deselect Cell Text', 'doublepoint=0.5:0.2', 'expectstate=Selected: nothing. Used: Alder.',
                  'forward=1', 'expectcontains=1901', 'backward=1', 'expectcontains=Alder',
                  f'fresh=scrolled:{size}:OPS/body.xhtml:normal',
                  'touch=Verification link', 'doublepoint=0.5:0.2', 'expect=Link target reached',
                  'forward=1', 'expect=This is the end', 'backward=1', 'expect=Link target reached',
                  'touch=Scroll Backward', 'mark=scroll', 'doublepoint=0.5:0.2', 'changed=scroll',
                  'entertext', 'focusvisible', 'forward=2', 'focusvisible', 'backward=2', 'focusvisible']
    return ','.join(steps)


def cache_workflow(size):
    steps = []
    for orientation in ('portrait', 'landscape'):
        steps += [f'rotate={orientation}', f'fresh=scrolled:{size}:OPS/chapter1.xhtml:normal',
                  'activate=Contents', 'activate=Chapter one', 'wait=2', 'forward=5', 'forward=18',
                  'touch=Scroll Forward', 'mark=scroll', 'doublepoint=0.5:0.2', 'changed=scroll',
                  'visible', 'entertext', 'forward=3', 'focusvisible', 'backward=3', 'focusvisible',
                  'touch=Scroll Backward', 'mark=back', 'doublepoint=0.5:0.2', 'changed=back',
                  'visible', 'entertext', 'forward=3', 'focusvisible']
    return ','.join(steps)


def menu_workflow(size):
    # #428 case 2: the physical iPad can return to controls or read into the previous
    # chapter; the probe validates both observed native continuations.
    steps = []
    for orientation in ('portrait', 'landscape'):
        steps += [f'rotate={orientation}', f'fresh=scrolled:{size}:OPS/chapter1.xhtml:normal',
                  'activate=Contents', 'activate=Chapter two', 'wait=2', 'forward=5',
                  'expect=Chapter two', 'forward=8', 'backward=8', 'expect=Chapter two',
                  'menuback']
    return ','.join(steps)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, default=Path('.build/voiceover/cursor-qualification'))
    parser.add_argument('--derived-data', type=Path, default=Path('.build/voiceover/ios-simulator'))
    parser.add_argument('--font-size', type=int, action='append', help='repeatable; default 17 and 23')
    parser.add_argument('--device', action='append', help='repeatable; default iPhone-17-Pro, iPhone-17-Pro-Max and iPad-Air-13-inch-M4')
    parser.add_argument('--workflow', choices=['all', 'reader', 'cache', 'menu'], default='all')
    args = parser.parse_args()
    def interrupted(number, frame):
        raise SystemExit(128 + number)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    runner = Path(__file__).with_name('run-voiceover-simulator.py')
    built = False
    # Pro Max exposed a silent-layout case after the original Pro/iPad matrix passed.
    kinds = args.device or ['iPhone-17-Pro', 'iPhone-17-Pro-Max', 'iPad-Air-13-inch-M4']
    for size in args.font_size or [17, 23]:
        for workflow in ['reader', 'cache', 'menu'] if args.workflow == 'all' else [args.workflow]:
            command = [sys.executable, '-u', str(runner), '--activation', 'cursor', '--runtime', activation.RUNTIME,
                       '--strict', '--font-size', str(size), '--launch', '-SampleSelectionLine YES -SampleControls none',
                       '--timeout', '1800', '--derived-data', str(args.derived_data),
                       '--results', str(args.results / f'{size}pt' / workflow), '--steps',
                       {'reader': workflows, 'cache': cache_workflow, 'menu': menu_workflow}[workflow](size)]
            for kind in kinds:
                command += ['--device', kind]
            if workflow == 'reader' and 'iPad-Air-13-inch-M4' in kinds:
                command += ['--device-steps', 'iPad-Air-13-inch-M4=' + workflows(size).replace('keyrotor=', 'rotor=')]
            if workflow in ('cache', 'menu'):
                command += ['--book', 'paragraphs', '--flow', 'scrolled']
            if built:
                command.append('--skip-build')
            process = subprocess.Popen(command)
            try:
                status = process.wait()
            finally:
                # The child runner owns restoration and deletion; do not strand it when
                # this matrix is interrupted between workflow groups.
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=120)
            if status:
                return status
            built = True
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
