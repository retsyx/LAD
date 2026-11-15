"""A failed display candidate remeshes only the solids that share its native meshes."""
from collections import Counter
from pathlib import Path
import sys
import unittest
from unittest import mock

import cadquery as cq
import OCP.BRepMesh as BRepMesh
from OCP.IMeshTools import IMeshTools_MeshAlgoType

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker

WATSON = IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Watson
DELABELLA = IMeshTools_MeshAlgoType.IMeshTools_MeshAlgoType_Delabella


class PreviewMeshRetryTests(unittest.TestCase):
    def preview_failing_once(self, shape, fails):
        """Fail the first candidate of faces selected by `fails`; record meshing and audits."""
        audit, mesher = worker._preview_face_triangles, BRepMesh.BRepMesh_IncrementalMesh
        failed, audited, meshed = set(), Counter(), []

        def candidate(face, poly, *rest):
            key = tuple(round(value, 6) for value in face.Center().toTuple())
            audited[key] += 1
            if fails(face) and not failed:
                failed.add(key)
                raise worker._PreviewMeshError("the triangulation contains inward surface triangles")
            return audit(face, poly, *rest)

        def capture(native, parameters):
            meshed.append((len(worker._shape_entities(cq.Shape.cast(native), "Solid")),
                           parameters.MeshAlgo, parameters.Angle, parameters.Deflection))
            return mesher(native, parameters)

        with (mock.patch.object(worker, "_preview_face_triangles", side_effect=candidate),
              mock.patch.object(BRepMesh, "BRepMesh_IncrementalMesh", side_effect=capture)):
            preview = worker.make_preview(shape)
        return preview, audited, meshed

    def test_failed_solid_retries_alone_with_the_independent_triangulator_first(self):
        shape = cq.Compound.makeCompound([cq.Solid.makeBox(2, 3, 4),
                                          cq.Solid.makeCylinder(2, 5, cq.Vector(10, 0, 0))])
        preview, audited, meshed = self.preview_failing_once(shape, lambda face: face.Center().x > 5)
        self.assertEqual(len(meshed), 2)
        (first_solids, first_algorithm, first_angle, deflection), retry = meshed
        self.assertEqual((first_solids, first_algorithm, first_angle), (2, WATSON, 0.15))
        self.assertEqual(retry, (1, DELABELLA, 0.16, deflection),
                         "Only the failed solid is remeshed, first at the same angle and deflection.")
        box = [key for key in audited if key[0] < 5]
        self.assertEqual(len(box), 6)
        self.assertTrue(all(audited[key] == 1 for key in box), "A healthy solid keeps its first native mesh.")
        self.assertEqual(preview["solids"], 2)
        self.assertEqual(sorted(set(preview["triangleSolids"])), [0, 1])

    def test_solids_sharing_native_subshapes_are_grouped(self):
        box = cq.Solid.makeBox(1, 1, 1)
        instances = cq.Compound.makeCompound([box, box.moved(cq.Location((3, 0, 0))),
                                              cq.Solid.makeSphere(1).translate((8, 0, 0))])
        self.assertEqual(worker._preview_solid_groups(worker._shape_entities(instances, "Solid")), [[0, 1], [2]])
        split = cq.Solid.makeBox(2, 1, 1).split(cq.Face.makePlane(4, 4, basePnt=(1, .5, .5), dir=(1, 0, 0)))
        pieces = worker._shape_entities(split, "Solid")
        self.assertEqual(len(pieces), 2)
        self.assertEqual(worker._preview_solid_groups(pieces), [[0, 1]], "Split solids share their cut face.")

    def test_located_instances_of_a_failed_solid_retry_together(self):
        box = cq.Solid.makeBox(1, 1, 1)
        shape = cq.Compound.makeCompound([box, box.moved(cq.Location((3, 0, 0))),
                                          cq.Solid.makeCylinder(1, 2, cq.Vector(10, 0, 0))])
        preview, audited, meshed = self.preview_failing_once(shape, lambda face: 2 < face.Center().x < 5)
        self.assertEqual([solids for solids, *_ in meshed], [3, 2],
                         "Both instances share one triangulation, so both are remeshed.")
        self.assertTrue(all(count == 1 for key, count in audited.items() if key[0] > 5))
        self.assertEqual(sorted(set(preview["triangleSolids"])), [0, 1, 2])


if __name__ == "__main__":
    unittest.main()
