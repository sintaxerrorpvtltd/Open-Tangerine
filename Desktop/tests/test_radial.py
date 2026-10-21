import os, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from PySide6.QtCore import QPointF, Qt
from PySide6.QtWidgets import QApplication
from radial import RadialGeometry, RadialWheel, StatusToast
from shell_integration import ShiftHold
from actions import available_actions
from PIL import Image


class RadialWheelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def image(self, name='test.png'):
        p = self.root / name
        Image.new('RGB', (16, 12), 'orange').save(p)
        return str(p)

    def test_geometry_and_wedge_angles(self):
        geom = RadialGeometry(4, inner_radius=50, outer_radius=120)
        self.assertEqual(geom.count, 4)
        for i in range(4):
            a0, a1 = geom.angles(i)
            self.assertAlmostEqual(a1 - a0, geom.slice)

    def test_geometry_hit_testing(self):
        geom = RadialGeometry(4, inner_radius=50, outer_radius=120)
        # Inside inner radius -> None
        self.assertIsNone(geom.index_at(QPointF(0, 0)))
        self.assertIsNone(geom.index_at(QPointF(20, 20)))

        # Far outside outer radius -> None
        self.assertIsNone(geom.index_at(QPointF(250, 250)))

        # Top area (0 degrees from 12 o'clock) should be index 0
        idx_top = geom.index_at(QPointF(0, -80))
        self.assertEqual(idx_top, 0)

        # Right area (3 o'clock) should be index 1
        idx_right = geom.index_at(QPointF(80, 0))
        self.assertEqual(idx_right, 1)

        # Bottom area (6 o'clock) should be index 2
        idx_bottom = geom.index_at(QPointF(0, 80))
        self.assertEqual(idx_bottom, 2)

        # Left area (9 o'clock) should be index 3
        idx_left = geom.index_at(QPointF(-80, 0))
        self.assertEqual(idx_left, 3)

    def test_radial_wheel_creation_and_actions(self):
        img = self.image()
        actions = available_actions([img])
        self.assertIn('JPEG', actions)
        self.assertIn('WEBP', actions)

        wheel = RadialWheel([img], actions)
        self.assertEqual(len(wheel.items), len(actions))
        self.assertEqual(wheel.paths, [img])
        self.assertEqual(wheel.title, 'test.png')

        # Test selection signal
        received = []
        wheel.action_selected.connect(lambda target, paths: received.append((target, paths)))
        wheel._trigger_selection('JPEG')
        self.assertEqual(received, [('JPEG', [img])])
        wheel.close()

    def test_status_toast_states(self):
        toast = StatusToast()
        toast.show_converting(2, 'JPEG')
        self.assertIn('JPEG', toast.title_label.text())

        toast.show_finished([str(self.root / 'out.jpg')])
        self.assertIn('complete', toast.title_label.text())
        self.assertTrue(toast.open_btn.isVisible())

        toast.show_error('Failure message')
        self.assertIn('error', toast.title_label.text())
        toast.close()

    def test_shift_hold_debounce_and_drag(self):
        sh = ShiftHold(delay=0.3)
        now = 100.0

        # No shift
        self.assertIsNone(sh.update(False, False, 1, now))

        # Shift pressed, start timing
        self.assertIsNone(sh.update(True, False, 1, now))
        self.assertIsNone(sh.update(True, False, 1, now + 0.1))

        # Shift held past 0.3s -> fires Select+Shift mode
        res = sh.update(True, False, 1, now + 0.35)
        self.assertEqual(res, (1, False))

        # Fired state does not repeat
        self.assertIsNone(sh.update(True, False, 1, now + 0.4))

        # Reset on release
        self.assertIsNone(sh.update(False, False, None, now + 0.5))

        # Drag + Shift: left button down + mouse moves >= 8px
        self.assertIsNone(sh.update(True, True, 2, now + 0.6, mouse_pos=(10, 10)))
        res_drag = sh.update(True, True, 2, now + 0.65, mouse_pos=(30, 30))
        self.assertEqual(res_drag, (2, True))


if __name__ == '__main__':
    unittest.main()
