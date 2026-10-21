"""File-type action intersection shared by the window and shell menu (GPL-3.0-only)."""
from pathlib import Path
from engine import IMAGE_INPUTS, IMAGE_OUTPUTS, MEDIA_INPUTS, MEDIA_OUTPUTS, OPERATIONS


def available_actions(paths):
    """Extensions suggest actions; workers still validate actual file contents."""
    if not paths:
        return []
    common = set(OPERATIONS)
    for path in paths:
        suffix = Path(path).suffix.lower()
        actions = {'SHA-256'}
        if suffix in IMAGE_INPUTS:
            actions.update(IMAGE_OUTPUTS)
            actions.add('Image → PDF')
        if suffix == '.pdf':
            actions.update(('PDF → Text', 'Split PDF'))
            if len(paths) > 1:
                actions.add('Merge PDFs')
        if suffix == '.srt':
            actions.add('SRT → VTT')
        if suffix == '.vtt':
            actions.add('VTT → SRT')
        if suffix in MEDIA_INPUTS:
            actions.update(MEDIA_OUTPUTS)
        common.intersection_update(actions)
    return [action for action in OPERATIONS if action in common]
