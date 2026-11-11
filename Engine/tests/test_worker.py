"""Geometry integration tests, including a real exported STEP re-import."""
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import ModelError, build_shape, make_preview, run, validate_spec

ROOT = Path(__file__).resolve().parents[2]


def script_spec(script):
    return {"title": "Python design", "summary": "Full CadQuery/OCP geometry test", "units": "mm",
            "script": script}


class ValidationTests(unittest.TestCase):
    def test_validation_receipt_includes_the_motion_adapter_rules(self):
        import cadquery as cq
        import worker
        spec = script_spec("result = cq.Solid.makeBox(1,2,3)")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = worker.validation_hash(spec, root, cq)
            read = Path.read_bytes
            adapter = Path(worker.__file__).with_name("assembly_motion.py")

            def changed(path):
                data = read(path)
                return data + b"\n# Updated mate validation\n" if path == adapter else data

            with mock.patch.object(Path, "read_bytes", changed):
                self.assertNotEqual(worker.validation_hash(spec, root, cq), original)

    def test_validation_receipt_reuses_checks_and_invalidates_changed_program(self):
        import worker
        import OCP.BRepCheck
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = root / "request.json"
            spec = script_spec("result = cq.Solid.makeBox(1,2,3)")
            request.write_text(json.dumps(spec))
            first = run(request, root / "first", 2, defer_step=True)
            receipt = first["validatedHash"]
            self.assertRegex(receipt, r"^[0-9a-f]{64}$")
            spec.update(title="Final saved title", summary="Final user-facing description")
            request.write_text(json.dumps(spec))
            with (mock.patch.object(worker, 'validate_step_roundtrip', side_effect=AssertionError('Repeated STEP validation')),
                  mock.patch.object(OCP.BRepCheck, 'BRepCheck_Analyzer', side_effect=AssertionError('Repeated exact validation'))):
                replay = run(request, root / "replay", 2, defer_step=True, validated_hash=receipt)
            self.assertEqual(replay["validatedHash"], receipt)
            for key in ('bounds', 'volume', 'area', 'solids', 'faces', 'topology'):
                self.assertEqual(first[key], replay[key])
            self.assertFalse((root / 'replay/model.step').exists())
            spec['script'] = "result = cq.Solid.makeBox(2,2,3)"
            request.write_text(json.dumps(spec))
            with mock.patch.object(worker, 'validate_step_roundtrip', wraps=worker.validate_step_roundtrip) as checked:
                changed = run(request, root / "changed", 2, defer_step=True, validated_hash=receipt)
                checked.assert_called_once()
            self.assertNotEqual(changed['validatedHash'], receipt)
            # A failed matching replay cannot leave the scoped bypass enabled.
            spec['script'] = "raise ValueError('replay failure')"
            request.write_text(json.dumps(spec))
            import cadquery as cq
            failed_receipt = worker.validation_hash(spec, root, cq)
            with self.assertRaisesRegex(ModelError, 'replay failure'):
                run(request, root / "failed", 2, defer_step=True, validated_hash=failed_receipt)
            self.assertFalse(worker._validated_replay.get())
            with self.assertRaises(ModelError):
                worker.build_shape(script_spec('result = cq.Solid.makeBox(1,1,1).translate((2e6,0,0))'))

    def test_validation_receipt_ignores_asset_name_but_revalidates_changed_bytes(self):
        import cadquery as cq
        import OCP.BRepCheck
        import worker
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = root / "request.json"
            asset = root / "input-000.step"
            cq.exporters.export(cq.Solid.makeBox(1, 2, 3), str(asset))
            spec = {**script_spec('result = imported_assets["reference"]'), 'inputAssets': [
                {'id': 'reference', 'name': 'Candidate reference', 'format': 'step', 'path': asset.name}]}
            request.write_text(json.dumps(spec))
            first = run(request, root / "first", 2, defer_step=True)
            receipt = first['validatedHash']
            spec.update(title="Saved title", summary="Saved summary")
            spec['inputAssets'][0]['name'] = "Renamed reference"
            request.write_text(json.dumps(spec))
            with (mock.patch.object(worker, 'validate_step_roundtrip', side_effect=AssertionError('Repeated STEP validation')),
                  mock.patch.object(OCP.BRepCheck, 'BRepCheck_Analyzer', side_effect=AssertionError('Repeated exact validation'))):
                replay = run(request, root / "replay", 2, defer_step=True, validated_hash=receipt)
            self.assertEqual(replay['validatedHash'], receipt)
            self.assertEqual(replay['volume'], first['volume'])
            cq.exporters.export(cq.Solid.makeBox(2, 2, 3), str(asset))
            with mock.patch.object(worker, 'validate_step_roundtrip', wraps=worker.validate_step_roundtrip) as checked:
                changed = run(request, root / "changed", 2, defer_step=True, validated_hash=receipt)
                checked.assert_called_once()
            self.assertNotEqual(changed['validatedHash'], receipt)
            self.assertAlmostEqual(changed['volume'], 2 * first['volume'])

    def test_matching_receipt_keeps_structural_and_size_guards(self):
        import cadquery as cq
        import worker
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = root / 'request.json'
            for index, (script, error) in enumerate([
                ("result = cq.Workplane('XY').circle(4)", 'only closed solids'),
                ("result = cq.Solid.makeBox(1,1,1).translate((2e6,0,0))", 'size limit')
            ]):
                spec = script_spec(script)
                request.write_text(json.dumps(spec))
                receipt = worker.validation_hash(spec, root, cq)
                with self.assertRaisesRegex(ModelError, error):
                    run(request, root / str(index), 2, defer_step=True, validated_hash=receipt)
                self.assertFalse(worker._validated_replay.get())

    def test_validation_hash_covers_external_bytes_runtime_and_worker_rules(self):
        import cadquery as cq
        import worker
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = {**script_spec('result = imported_model'), 'sourceAsset': 'source.step'}
            source = root / 'source.step'
            source.write_bytes(b'first reference bytes')
            first = worker.validation_hash(spec, root, cq)
            source.write_bytes(b'changed reference bytes')
            self.assertNotEqual(first, worker.validation_hash(spec, root, cq))
            spec = {**script_spec('result = imported_assets["a"]'), 'inputAssets': [
                {'id': 'a', 'name': 'Reference', 'format': 'brep', 'path': 'input-000.brep'}]}
            asset = root / 'input-000.brep'
            asset.write_bytes(b'asset bytes')
            first = worker.validation_hash(spec, root, cq)
            asset.write_bytes(b'changed asset bytes')
            self.assertNotEqual(first, worker.validation_hash(spec, root, cq))
            first = worker.validation_hash(spec, root, cq)
            with mock.patch.object(worker, 'runtime_info', return_value={'python': 'changed'}):
                self.assertNotEqual(worker.validation_hash(spec, root, cq), first)
            with mock.patch.object(worker, '__file__', str(source)):
                self.assertNotEqual(worker.validation_hash(spec, root, cq), first)

    def test_validation_hash_covers_input_presence_identity_format_and_order(self):
        import cadquery as cq
        import worker
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('source.step', 'input-000.brep', 'input-001.brep', 'input-000.step'):
                (root / name).write_bytes(b'identical reference bytes')
            spec = script_spec('result = imported_assets["a"]')
            no_inputs = worker.validation_hash(spec, root, cq)
            spec['sourceAsset'] = 'source.step'
            self.assertNotEqual(no_inputs, worker.validation_hash(spec, root, cq))
            del spec['sourceAsset']
            spec['inputAssets'] = [
                {'id': 'a', 'name': 'A', 'format': 'brep', 'path': 'input-000.brep'},
                {'id': 'b', 'name': 'B', 'format': 'brep', 'path': 'input-001.brep'}]
            original = worker.validation_hash(spec, root, cq)
            spec['inputAssets'][0]['id'], spec['inputAssets'][1]['id'] = 'b', 'a'
            self.assertNotEqual(original, worker.validation_hash(spec, root, cq))
            spec['inputAssets'][0]['id'], spec['inputAssets'][1]['id'] = 'a', 'b'
            spec['inputAssets'][0].update(format='step', path='input-000.step')
            self.assertNotEqual(original, worker.validation_hash(spec, root, cq))

    def test_script_validation_happens_before_execution(self):
        invalid = [script_spec(None), script_spec(17), script_spec("x" * 200_001),
                   script_spec("é" * 100_001), script_spec(""), script_spec(" \n")]
        missing = script_spec("result = cq.Solid.makeBox(1,1,1)")
        del missing["script"]
        invalid.append(missing)
        for value in invalid:
            with self.subTest(value=str(value)[:120]), self.assertRaises(ModelError):
                validate_spec(value)
        for source in ("result = cq.Workplane('XY').box(1,2,3)", "#" + "é" * 99_999 + "x"):
            value = script_spec(source)
            self.assertIs(validate_spec(value), value)

    def test_rejects_missing_metadata_unsupported_units_and_extra_protocol_fields(self):
        valid = script_spec("result = cq.Workplane('XY').box(1,2,3)")
        invalid = [None, [], "not a request"]
        for field in ("title", "summary", "units"):
            value = dict(valid)
            del value[field]
            invalid.append(value)
        for field, content in (("title", ""), ("title", "x" * 161), ("title", 17),
                               ("summary", ""), ("summary", "x" * 6001),
                               ("units", "in"), ("units", None)):
            invalid.append({**valid, field: content})
        # Construction requests expose one complete program, without a second
        # operation protocol or arbitrary executable metadata.
        for field, content in (("nodes", []), ("result", "result"),
                               ("code", "print('unrecognized field')"), ("operation", "build")):
            invalid.append({**valid, field: content})
        for value in invalid:
            with self.subTest(value=str(value)[:120]), self.assertRaises(ModelError):
                validate_spec(value)

    def test_script_errors_are_actionable_and_result_must_be_solid(self):
        cases = [("a = 1", "must assign"), ("result = 42", "must be a CadQuery"),
                 ("result = cq.Workplane('XY').circle(4)", "only closed solids"),
                 ("if True\n  result = None", "SyntaxError"),
                 ("raise ValueError('bad profile')", "line 1: ValueError: bad profile"),
                 ("raise SystemExit(0)", "SystemExit"),
                 ("result = cq.Solid.makeBox(1,2,3).translate((2e6,0,0))", "size limit")]
        for source, diagnostic in cases:
            with self.subTest(source=source), self.assertRaisesRegex(ModelError, diagnostic):
                build_shape(script_spec(source), 2)

    def test_rejects_empty_intersection(self):
        value = script_spec("""
a = cq.Solid.makeSphere(1, angleDegrees1=-90, angleDegrees2=90)
result = a.intersect(a.translate((50, 0, 0))).clean()
""")
        with self.assertRaisesRegex(ModelError, "only closed solids"):
            build_shape(value, 2)


class GeometryTests(unittest.TestCase):
    def test_deferred_step_verifies_then_discards_step_and_retains_native_solid(self):
        import cadquery as cq
        from worker import write_step
        from OCP.BRep import BRep_Builder, BRep_Tool
        from OCP.BRepTools import BRepTools
        from OCP.TopLoc import TopLoc_Location
        from OCP.TopoDS import TopoDS_Shape
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / 'request.json'
            request.write_text(json.dumps(script_spec("""
result = cq.Assembly(name='Case', metadata={'lad_id':'case'})
result.add(cq.Solid.makeBox(7,8,2), name='Base', metadata={'lad_id':'base'})
result.add(cq.Solid.makeCylinder(2,3), name='Post', loc=cq.Location((20,5,2)), metadata={'lad_id':'post'})
""")))
            with mock.patch('worker.write_step', wraps=write_step) as export_step:
                preview = run(request, folder, 4, defer_step=True)
            self.assertEqual(export_step.call_count, 1, 'Candidates must pass STEP verification before preview acceptance')
            validation_path = Path(export_step.call_args.args[1])
            self.assertFalse(validation_path.exists(), 'Verification STEP must be removed after acceptance')
            self.assertFalse(validation_path.parent.exists(), 'Verification workspace must be removed after acceptance')
            self.assertFalse((folder / 'model.step').exists())
            self.assertTrue(Path(preview['brepPath']).is_file())
            self.assert_part_ownership(preview)
            self.assertEqual(set(preview['runtime']), {'python', 'cadquery', 'ocp'})
            wrapped = TopoDS_Shape()
            self.assertTrue(BRepTools.Read_s(wrapped, preview['brepPath'], BRep_Builder()))
            native = cq.Shape.cast(wrapped)
            self.assertTrue(all(BRep_Tool.Triangulation_s(face.wrapped, TopLoc_Location()) is None
                                for face in native.Faces()), 'Transient native geometry must omit derived display data')
            export = folder / 'export'
            export.mkdir()
            (export / 'source.brep').write_bytes(Path(preview['brepPath']).read_bytes())
            export_request = export / 'request.json'
            export_request.write_text(json.dumps({'operation': 'export', 'brepAsset': 'source.brep'}))
            request.unlink()
            with (mock.patch('worker.build_shape', side_effect=AssertionError('No program replay')),
                  mock.patch('worker.make_preview', side_effect=AssertionError('No meshing for export'))):
                exported = run(export_request, export, 4)
            restored = cq.importers.importStep(exported['stepPath']).val()
            self.assertEqual(len(restored.Solids()), preview['solids'])
            self.assertAlmostEqual(restored.Volume(), preview['volume'], places=6)
            for original, actual in zip(native.Solids(), restored.Solids()):
                a, b = original.BoundingBox(), actual.BoundingBox()
                for axis in ('xmin', 'ymin', 'zmin', 'xmax', 'ymax', 'zmax'):
                    self.assertAlmostEqual(getattr(a, axis), getattr(b, axis), places=6)

    def test_fast_triangulation_preserves_exact_vertices_and_oriented_winding(self):
        import cadquery as cq
        shape = cq.Compound.makeCompound([
            cq.Solid.makeBox(7,8,2).cut(cq.Solid.makeCylinder(1,4).translate((2,3,-1))),
            cq.Solid.makeSphere(3, angleDegrees1=-90, angleDegrees2=90).translate((20,0,0))])
        preview = make_preview(shape)
        bounds = shape.BoundingBox()
        tolerance = max(0.005, min(0.25, math.sqrt(bounds.xlen**2 + bounds.ylen**2 + bounds.zlen**2)/1000))
        vertices, triangles, owners = [], [], []
        for owner, solid in enumerate(shape.Solids()):
            values, indices = solid.tessellate(tolerance, .15)
            offset = len(vertices)
            vertices.extend(list(value.toTuple()) for value in values)
            triangles.extend([i+offset for i in triangle] for triangle in indices)
            owners.extend([owner]*len(indices))
        self.assertEqual(preview['vertices'], vertices)
        self.assertEqual(preview['triangles'], triangles)
        self.assertEqual(preview['triangleSolids'], owners)

    def test_export_rejects_unrelated_or_nonregular_native_assets(self):
        from worker import write_brep
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / 'request.json'
            for asset in ('../unrelated.brep', '/tmp/unrelated.brep'):
                request.write_text(json.dumps({'operation': 'export', 'brepAsset': asset}))
                with self.assertRaisesRegex(ModelError, 'private source.brep'):
                    run(request, folder, 2)
            request.write_text(json.dumps({'operation': 'export', 'brepAsset': 'source.brep'}))
            (folder / 'source.brep').write_bytes(b'invalid native geometry')
            with self.assertRaisesRegex(ModelError, 'native solid asset is invalid'):
                run(request, folder, 2)
            (folder / 'source.brep').unlink()
            write_brep(cq.Solid.makeBox(1,2,3), folder / 'original.brep')
            (folder / 'source.brep').symlink_to(folder / 'original.brep')
            with self.assertRaisesRegex(ModelError, 'regular private file'):
                run(request, folder, 2)

    def assert_part_ownership(self, preview):
        identifiers, owners = [], []

        def visit(parts):
            for part in parts:
                identifiers.append(part["id"])
                self.assertTrue(part["name"])
                owners.extend(part["solidIndices"])
                if part["solidIndices"]:
                    self.assertIsNone(part["children"], "Every physical body must have its own leaf row")
                    self.assertEqual(len(part["solidIndices"]), 1)
                else:
                    self.assertIsInstance(part["children"], list)
                visit(part.get("children") or [])

        visit(preview["parts"])
        self.assertEqual(len(identifiers), len(set(identifiers)))
        self.assertEqual(sorted(owners), list(range(preview["solids"])))
        self.assertEqual(len(preview["edgeSolids"]), len(preview["edges"]))
        self.assertEqual(set(preview["edgeSolids"]), set(range(preview["solids"])))

    def test_named_nested_assembly_parts_preserve_locations_and_step(self):
        import cadquery as cq
        source = """
base = cq.Solid.makeBox(4,6,8).moved(cq.Location((2,0,0)))
case = cq.Assembly(base, name='Case', loc=cq.Location((10,0,0)), metadata={'lad_id':'case'})
case.add(cq.Solid.makeBox(1,2,3), name='Lid', loc=cq.Location((0,20,0)), metadata={'lad_id':'lid'})
pcb = cq.Compound.makeCompound([cq.Solid.makeBox(2,3,1), cq.Solid.makeBox(1,1,2).translate((8,0,0))])
result = cq.Assembly(name='Product', loc=cq.Location((100,-40,15),(0,0,1),90))
result.add(case)
result.add(pcb, name='PCB', loc=cq.Location((40,0,0)))
"""
        shape = build_shape(script_spec(source), 2)
        preview = make_preview(shape)
        self.assert_part_ownership(preview)
        product = preview["parts"][0]
        self.assertEqual(product["name"], "Product")
        case, pcb = product["children"]
        self.assertEqual((case["name"], case["id"], case["solidIndices"]), ("Case", "case", []))
        self.assertEqual(case["children"][0]["id"], 'body:["case",0]')
        self.assertEqual(case["children"][0]["solidIndices"], [0])
        self.assertEqual(case["children"][1]["id"], "lid")
        self.assertEqual(case["children"][1]["solidIndices"], [1])
        self.assertEqual((pcb["name"], pcb["id"], pcb["solidIndices"]), ("PCB", "name:PCB", []))
        self.assertEqual([part["solidIndices"] for part in pcb["children"]], [[2], [3]])
        # The root rotation and all nested locations affect both picking and
        # exact export, without recentering or altering stored CAD coordinates.
        expected_centers = [(97,-26,19), (79,-29.5,16.5), (98.5,1,15.5), (99.5,8.5,16)]
        for solid, expected in zip(shape.Solids(), expected_centers):
            for actual, value in zip(solid.Center().toTuple(), expected):
                self.assertAlmostEqual(actual, value, places=6)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            request = folder / "request.json"
            request.write_text(json.dumps(script_spec(source)))
            result = run(request, folder, 2)
            self.assertEqual(result["parts"], preview["parts"])
            restored = cq.importers.importStep(result["stepPath"]).val()
            self.assertEqual(len(restored.Solids()), 4)
            self.assertAlmostEqual(restored.Volume(), shape.Volume(), places=6)
            for actual, expected in zip(sorted(s.Center().toTuple() for s in restored.Solids()), sorted(expected_centers)):
                for coordinate, value in zip(actual, expected):
                    self.assertAlmostEqual(coordinate, value, places=6)

    def test_saved_step_regenerates_named_assembly_preview_without_building_or_exporting(self):
        import cadquery as cq
        source = """
body = cq.Solid.makeBox(3,4,5)
case = cq.Assembly(name='Case', loc=cq.Location((10,0,0)), metadata={'lad_id':'case'})
case.add(body, name='Base', metadata={'lad_id':'base'})
case.add(body, name='Lid', loc=cq.Location((0,0,20)), metadata={'lad_id':'lid'})
pcb = cq.Compound.makeCompound([cq.Solid.makeBox(7,8,1), cq.Solid.makeCylinder(2,3).translate((2,3,1))])
result = cq.Assembly(name='Product', loc=cq.Location((100,-40,15),(0,0,1),90))
result.add(case)
result.add(pcb, name='PCB', loc=cq.Location((40,0,0)), metadata={'lad_id':'pcb'})
"""
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            build = folder / 'build'
            build.mkdir()
            request = build / 'request.json'
            request.write_text(json.dumps(script_spec(source)))
            original = run(request, build, 2)
            exact_step = Path(original['stepPath']).read_bytes()
            # Removing the complete CAD program and staging only the exact
            # STEP plus semantic IDs must suffice, even in a fresh directory.
            request.unlink()
            preview_folder = folder / 'preview'
            preview_folder.mkdir()
            (preview_folder / 'preview.step').write_bytes(exact_step)
            request = preview_folder / 'request.json'
            request.write_text(json.dumps({'operation': 'preview', 'stepAsset': 'preview.step', 'parts': original['parts']}))
            with mock.patch('worker.build_shape', side_effect=AssertionError('program was rebuilt')), \
                    mock.patch.object(cq.exporters, 'export', side_effect=AssertionError('saved STEP was re-exported')):
                regenerated = run(request, preview_folder, 4)
            self.assertEqual(Path(regenerated['stepPath']).read_bytes(), exact_step)
            self.assertEqual(regenerated['parts'], original['parts'])
            self.assertEqual(regenerated['solids'], 4)
            self.assertEqual(regenerated['threads'], 4)
            self.assert_part_ownership(regenerated)
            self.assertAlmostEqual(regenerated['volume'], original['volume'], places=6)
            # Compare each solid owner, rather than sorted global bounds:
            # swapping the repeated Base/Lid instances would break visibility
            # and selection even though total geometry remained identical.
            def owned_bounds(preview, index):
                vertices = [preview['vertices'][vertex] for triangle, owner in
                            zip(preview['triangles'], preview['triangleSolids']) if owner == index for vertex in triangle]
                return [min(vertex[axis] for vertex in vertices) for axis in range(3)] + \
                       [max(vertex[axis] for vertex in vertices) for axis in range(3)]
            for index in range(4):
                for actual, expected in zip(owned_bounds(regenerated, index), owned_bounds(original, index)):
                    self.assertAlmostEqual(actual, expected, places=5)
                original_edges = [edge for edge, owner in zip(original['edges'], original['edgeSolids']) if owner == index]
                regenerated_edges = [edge for edge, owner in zip(regenerated['edges'], regenerated['edgeSolids']) if owner == index]
                for axis in range(3):
                    for extreme in (min, max):
                        self.assertAlmostEqual(extreme(edge[pos] for edge in regenerated_edges for pos in (axis, axis + 3)),
                                               extreme(edge[pos] for edge in original_edges for pos in (axis, axis + 3)), places=5)

    def test_saved_step_preview_imports_every_transfer_root(self):
        import cadquery as cq
        from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            writer = STEPControl_Writer()
            writer.Transfer(cq.Solid.makeBox(2,3,4).wrapped, STEPControl_AsIs)
            writer.Transfer(cq.Solid.makeBox(3,4,5).translate((30,0,0)).wrapped, STEPControl_AsIs)
            writer.Write(str(folder / 'preview.step'))
            exact_step = (folder / 'preview.step').read_bytes()
            request = folder / 'request.json'
            request.write_text(json.dumps({'operation': 'preview', 'stepAsset': 'preview.step'}))
            preview = run(request, folder, 2)
            self.assertEqual(preview['solids'], 2)
            self.assertAlmostEqual(preview['volume'], 84, places=6)
            self.assertAlmostEqual(preview['bounds'][3], 33, places=6)
            self.assertEqual(Path(preview['stepPath']).read_bytes(), exact_step)
            self.assert_part_ownership(preview)

            # Replaying a model must retain every imported STEP transfer root.
            (folder / 'source.step').write_bytes(exact_step)
            request.write_text(json.dumps({**script_spec('result = imported_model'), 'sourceAsset': 'source.step'}))
            replayed = run(request, folder, 2, defer_step=True)
            self.assertEqual(replayed['solids'], 2)
            self.assertAlmostEqual(replayed['volume'], 84, places=6)
            self.assertAlmostEqual(replayed['bounds'][3], 33, places=6)

    def test_saved_step_preview_rejects_invalid_assets_and_semantic_ownership(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            cq.exporters.export(cq.Solid.makeBox(1,2,3), str(folder / 'preview.step'))
            request = folder / 'request.json'
            spec = {'operation': 'preview', 'stepAsset': 'preview.step'}
            for parts in ([], [{'id': 'one', 'name': 'One', 'solidIndices': [1]}],
                          [{'id': 'one', 'name': 'One', 'solidIndices': [0,0]}],
                          [{'id': 'one', 'name': 'One', 'solidIndices': [0]},
                           {'id': 'one', 'name': 'Two', 'solidIndices': [], 'children': []}]):
                request.write_text(json.dumps({**spec, 'parts': parts}))
                with self.subTest(parts=parts), self.assertRaises(ModelError):
                    run(request, folder, 2)
            request.write_text(json.dumps({**spec, 'stepAsset': '../unrelated.step'}))
            with self.assertRaisesRegex(ModelError, 'private preview.step'):
                run(request, folder, 2)
            (folder / 'preview.step').rename(folder / 'original.step')
            (folder / 'preview.step').symlink_to(folder / 'original.step')
            request.write_text(json.dumps(spec))
            with self.assertRaisesRegex(ModelError, 'regular private file'):
                run(request, folder, 2)

    def test_assembly_root_body_and_children_have_individual_leaf_rows(self):
        source = """
result = cq.Assembly(cq.Solid.makeBox(10,8,2), name='Base', metadata={'lad_id':'base'})
result.add(cq.Solid.makeBox(10,8,1), name='Lid', loc=cq.Location((0,0,5)), metadata={'lad_id':'lid'})
"""
        preview = make_preview(build_shape(script_spec(source), 2))
        self.assert_part_ownership(preview)
        root = preview["parts"][0]
        self.assertEqual(root["solidIndices"], [])
        self.assertEqual([(part["id"], part["name"], part["solidIndices"], part["children"])
                          for part in root["children"]],
                         [('body:["base",0]', 'Base', [0], None), ('lid', 'Lid', [1], None)])
        # A user-created folder reused as an Assembly must remain a folder
        # even when the CAD program puts its sole body on the root object.
        for identity in ("folder:123", "user-folder:123"):
            folder = make_preview(build_shape(script_spec(f"result=cq.Assembly(cq.Solid.makeBox(1,2,3),name='Custom',metadata={{'lad_id':'{identity}'}})"), 2))
            self.assert_part_ownership(folder)
            self.assertEqual(folder["parts"][0]["id"], identity)
            self.assertEqual(folder["parts"][0]["solidIndices"], [])
            self.assertEqual(folder["parts"][0]["children"][0]["id"], f'body:["{identity}",0]')

    def test_compound_alias_infers_case_and_pcb_without_changing_geometry(self):
        import cadquery as cq
        source = """
base = cq.Workplane('XY').box(40,30,3).translate((100,-40,7))
lid = cq.Solid.makeBox(40,30,2).translate((80,-55,30))
pcb = cq.Compound.makeCompound([cq.Solid.makeBox(20,15,1).translate((90,-48,12)),
                               cq.Solid.makeBox(3,4,5).translate((94,-44,13))])
tmp = pcb
imported_model = pcb
result = cq.Compound.makeCompound([base.val(),lid,pcb])
"""
        expected_namespace = {"cq": cq}
        exec(source, expected_namespace)
        expected = expected_namespace["result"]
        shape = build_shape(script_spec(source), 2)
        preview = make_preview(shape)
        self.assert_part_ownership(preview)
        case, pcb = preview["parts"]
        self.assertEqual((case["id"], case["name"]), ("case", "Case"))
        self.assertEqual([(part["id"], part["name"], part["solidIndices"]) for part in case["children"]],
                         [("case-base", "Base", [0]), ("case-lid", "Lid", [1])])
        self.assertEqual((pcb["id"], pcb["name"], len(pcb["children"])), ("pcb", "PCB", 2))
        self.assertEqual(shape.ShapeType(), "Compound")
        # Retain the compound's original three children and complete
        # solid ordering. The inferred Case group exists only in metadata.
        self.assertEqual(len(list(shape)), 3)
        self.assertEqual(len(shape.Solids()), 4)
        self.assertAlmostEqual(shape.Volume(), expected.Volume(), places=6)
        expected_centers = [solid.Center().toTuple() for solid in expected.Solids()]
        self.assertEqual([solid.Center().toTuple() for solid in shape.Solids()], expected_centers)
        expected_bounds = expected.BoundingBox()
        self.assertEqual(preview["bounds"], [expected_bounds.xmin, expected_bounds.ymin, expected_bounds.zmin,
                                           expected_bounds.xmax, expected_bounds.ymax, expected_bounds.zmax])
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "request.json"
            request.write_text(json.dumps(script_spec(source)))
            result = run(request, Path(directory), 2)
            restored = cq.importers.importStep(result["stepPath"]).val()
            self.assertAlmostEqual(restored.Volume(), expected.Volume(), places=6)
            self.assertEqual(len(restored.Solids()), 4)
            for actual, center in zip([solid.Center().toTuple() for solid in restored.Solids()], expected_centers):
                for value, coordinate in zip(actual, center):
                    self.assertAlmostEqual(value, coordinate, places=6)

    def test_compound_alias_retains_named_nested_variables_and_generic_bodies(self):
        source = """
shaft = cq.Workplane('XY').cylinder(8,2)
gear = cq.Solid.makeCylinder(5,2).translate((0,0,10))
gearbox = cq.Compound.makeCompound([shaft.val(),gear])
result = cq.Compound.makeCompound([gearbox,cq.Solid.makeBox(2,3,4).translate((30,0,0))])
"""
        preview = make_preview(build_shape(script_spec(source), 2))
        self.assert_part_ownership(preview)
        gearbox, anonymous = preview["parts"]
        self.assertEqual((gearbox["id"], gearbox["name"]), ("legacy:gearbox", "Gearbox"))
        self.assertEqual([(part["id"], part["name"]) for part in gearbox["children"]],
                         [("legacy:shaft", "Shaft"), ("legacy:gear", "Gear")])
        self.assertEqual((anonymous["id"], anonymous["name"]), ("solid/2", "Part 3"))
        unnamed = make_preview(build_shape(script_spec("result=cq.Compound.makeCompound([cq.Solid.makeBox(1,2,3),cq.Solid.makeBox(1,2,3).translate((10,0,0))])"), 2))
        self.assertEqual([part["id"] for part in unnamed["parts"]], ["solid/0", "solid/1"])

    def test_part_ids_survive_reparenting_root_rename_and_duplicate_instances(self):
        source = """
body = cq.Solid.makeBox(2,3,4)
left = cq.Assembly(name='Left')
left.add(body, name='Bolt', loc=cq.Location((10,0,0)), metadata={'lad_id':'bolt-left'})
right = cq.Assembly(name='Right')
right.add(body, name='Bolt', loc=cq.Location((20,0,0)), metadata={'lad_id':'bolt-right'})
right.add(body, name='Spacer', loc=cq.Location((30,0,0)))
result = cq.Assembly(name='Old title')
result.add(left)
result.add(right)
"""
        first = make_preview(build_shape(script_spec(source), 2))
        # Move a uniquely named part to another folder and rename the outer
        # model. Explicit IDs and unique basenames must remain the same.
        changed = source.replace("right.add(body, name='Spacer'", "left.add(body, name='Spacer'").replace("Old title", "New title")
        second = make_preview(build_shape(script_spec(changed), 2))
        self.assert_part_ownership(first)
        self.assert_part_ownership(second)

        def identities(parts):
            return {part["id"] for part in parts} | set().union(*(identities(part["children"] or []) for part in parts))

        self.assertEqual(identities(first["parts"]), identities(second["parts"]))
        self.assertIn("name:Spacer", identities(first["parts"]))
        self.assertIn("bolt-left", identities(first["parts"]))
        self.assertIn("bolt-right", identities(first["parts"]))
        # Duplicate display names without explicit IDs remain distinct and
        # deterministic using their folder paths, independent of root title.
        anonymous = source.replace(", metadata={'lad_id':'bolt-left'}", "").replace(", metadata={'lad_id':'bolt-right'}", "")
        third = make_preview(build_shape(script_spec(anonymous), 2))
        fourth = make_preview(build_shape(script_spec(anonymous.replace("Old title", "New title")), 2))
        self.assert_part_ownership(third)
        self.assertEqual(identities(third["parts"]), identities(fourth["parts"]))

    def test_assembly_ids_validate_and_default_uuid_names_are_stable(self):
        source = """
result = cq.Assembly()
result.add(cq.Solid.makeBox(1,2,3), name='Base')
result.add(cq.Solid.makeBox(1,2,3), name='Lid', loc=cq.Location((10,0,0)))
"""
        first = make_preview(build_shape(script_spec(source), 2))
        second = make_preview(build_shape(script_spec(source), 2))
        self.assertEqual(first["parts"], second["parts"])
        self.assertEqual([part["name"] for part in first["parts"]], ["Base", "Lid"])
        self.assert_part_ownership(first)
        duplicate = source.replace("name='Base'", "name='Base', metadata={'lad_id':'duplicate'}").replace("name='Lid'", "name='Lid', metadata={'lad_id':'duplicate'}")
        with self.assertRaisesRegex(ModelError, "lad_id must be unique"):
            build_shape(script_spec(duplicate), 2)
        # Raw explicit IDs can reuse a user-created folder or an ID that
        # resembles a generated namespace without causing duplicate IDs.
        collision = source.replace("name='Base'", "name='Base', metadata={'lad_id':'name:Lid'}")
        preview = make_preview(build_shape(script_spec(collision), 2))
        self.assert_part_ownership(preview)
        self.assertEqual([part["id"] for part in preview["parts"]], ["name:Lid", "generated:name:Lid"])

    def test_native_step_source_is_imported_and_used_for_refinement(self):
        import cadquery as cq
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = cq.Workplane("XY").box(20, 15, 4).val()
            cq.exporters.export(original, str(folder / "source.step"))
            value = script_spec("result = imported_model.translate((40, 0, 0))")
            value["sourceAsset"] = "source.step"
            request = folder / "request.json"
            request.write_text(json.dumps(value))
            preview = run(request, folder, 2)
            self.assertAlmostEqual(preview["volume"], original.Volume(), places=5)
            self.assertAlmostEqual(preview["bounds"][0], 30, places=5)
            self.assertEqual(preview["solids"], 1)
            restored = cq.importers.importStep(preview["stepPath"]).val()
            self.assertTrue(restored.isValid())

    def test_native_source_asset_rejects_arbitrary_paths_and_links(self):
        value = script_spec("result = imported_model")
        value["sourceAsset"] = "../private.step"
        with self.assertRaisesRegex(ModelError, "private source.step"):
            validate_spec(value)
        value["sourceAsset"] = "source.step"
        with self.assertRaisesRegex(ModelError, "directory is unavailable"):
            build_shape(value, 2)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            target = folder / "other.step"
            target.write_text("ISO-10303-21;\nEND-ISO-10303-21;")
            (folder / "source.step").symlink_to(target)
            with self.assertRaisesRegex(ModelError, "regular private file"):
                build_shape(value, 2, folder)

    def test_full_python_bezier_nonuniform_scale_loft_assembly_step(self):
        import cadquery as cq
        source = """
profile = (cq.Workplane('XZ').moveTo(0,0).lineTo(12,0)
    .bezier([(14,1),(14,8),(12,10)], includeCurrent=True)
    .lineTo(0,10).close())
pebble = profile.revolve(360).val()
pebble = pebble.transformGeometry(cq.Matrix([
    [1,0,0,0], [0,0.7,0,0], [0,0,1,0], [0,0,0,1]]))
loft = cq.Workplane('XY').circle(4).workplane(offset=6).rect(3,5).loft(combine=False)
result = cq.Assembly(pebble, name='pebble', loc=cq.Location((5,6,7)))
result.add(loft, name='loft', loc=cq.Location((40,0,0)))
"""
        value = script_spec(source)
        shape = build_shape(value, 2)
        self.assertTrue(shape.isValid())
        self.assertEqual(len(shape.Solids()), 2)
        self.assertAlmostEqual(shape.BoundingBox().zmin, 7, places=5)
        self.assertGreater(shape.BoundingBox().xmax, 45)
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "request.json"
            request.write_text(json.dumps(value))
            preview = run(request, Path(directory), 2)
            imported = cq.importers.importStep(preview["stepPath"]).val()
            self.assertTrue(imported.isValid())
            self.assertEqual(len(imported.Solids()), 2)
            self.assertAlmostEqual(imported.Volume(), shape.Volume(), places=3)
            self.assertEqual(set(preview["triangleSolids"]), {0, 1})

    def test_direct_opencascade_workplane_values_and_sweep(self):
        raw = build_shape(script_spec("from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox\nresult = BRepPrimAPI_MakeBox(4,5,6).Shape()"), 2)
        self.assertAlmostEqual(raw.Volume(), 120)
        values = build_shape(script_spec("result = cq.Workplane('XY').newObject([cq.Solid.makeBox(2,3,4), cq.Solid.makeBox(2,3,4).translate((10,0,0))])"), 2)
        self.assertEqual(len(values.Solids()), 2)
        self.assertAlmostEqual(values.Volume(), 48)
        swept = build_shape(script_spec("path = cq.Workplane('XZ').spline([(0,0),(8,2),(16,8)])\nresult = cq.Workplane('YZ').circle(1).sweep(path)"), 2)
        self.assertTrue(swept.isValid())
        self.assertGreater(swept.Volume(), 40)

    def test_primitives_have_expected_volume(self):
        cases = [("cq.Workplane('XY').box(10,20,30,centered=(True,True,False))", 6000),
                 ("cq.Solid.makeCylinder(5,10)", math.pi * 250),
                 ("cq.Solid.makeSphere(5,angleDegrees1=-90,angleDegrees2=90)", 4 / 3 * math.pi * 125),
                 ("cq.Solid.makeCone(5,0,10)", math.pi * 250 / 3),
                 ("cq.Solid.makeTorus(10,2)", 2 * math.pi ** 2 * 10 * 4)]
        for expression, volume in cases:
            with self.subTest(expression=expression):
                shape = build_shape(script_spec("result = " + expression), 2)
                self.assertAlmostEqual(shape.Volume(), volume, places=5)
                self.assertTrue(shape.isValid())

    def test_profiles_patterns_booleans_and_finishing(self):
        extruded = build_shape(script_spec("result = cq.Workplane('XY').polyline([(0,0),(10,0),(10,20),(0,20)]).close().extrude(5)"), 2)
        self.assertAlmostEqual(extruded.Volume(), 1000)
        revolved = build_shape(script_spec("result = cq.Workplane('XZ').polyline([(0,0),(5,0),(5,10),(0,10)]).close().revolve(360,(0,0),(0,1))"), 2)
        self.assertAlmostEqual(revolved.Volume(), math.pi * 250, places=5)
        self.assertAlmostEqual(revolved.BoundingBox().zlen, 10, places=6)
        patterned = build_shape(script_spec("""
body = cq.Workplane('XY').box(2,2,2,centered=(True,True,False)).val()
result = body.fuse(*(body.translate((5 * i,0,0)) for i in range(1,3))).clean()
"""), 2)
        self.assertEqual(len(patterned.Solids()), 3)
        self.assertAlmostEqual(patterned.Volume(), 24)
        intersection = build_shape(script_spec("""
a = cq.Workplane('XY').box(10,10,10,centered=(True,True,False)).val()
result = a.intersect(a.translate((5,0,0))).clean()
"""), 2)
        self.assertAlmostEqual(intersection.Volume(), 500)
        cut = build_shape(script_spec("result = cq.Solid.makeBox(10,10,10).cut(cq.Solid.makeCylinder(2,12).translate((5,5,-1))).clean()"), 2)
        self.assertAlmostEqual(cut.Volume(), 1000 - math.pi * 40, places=5)
        chamfer = build_shape(script_spec("result = cq.Workplane('XY').box(10,10,10).edges('|Z').chamfer(1)"), 2)
        self.assertAlmostEqual(chamfer.Volume(), 980)
        fillet = build_shape(script_spec("result = cq.Workplane('XY').box(10,10,10).edges('|Z').fillet(1)"), 2)
        self.assertGreater(fillet.Volume(), 980)
        self.assertLess(fillet.Volume(), 1000)
        shell = build_shape(script_spec("result = cq.Workplane('XY').box(10,10,10).faces('>Z').shell(-1)"), 2)
        self.assertAlmostEqual(shell.Volume(), 1000 - 8 * 8 * 9, places=5)
        rotated = build_shape(script_spec("result = cq.Solid.makeBox(2,3,4).rotate((0,0,0),(0,0,1),90).translate((10,20,30))"), 2)
        self.assertAlmostEqual(rotated.Volume(), 24)
        self.assertAlmostEqual(rotated.BoundingBox().xmin, 7, places=5)
        self.assertAlmostEqual(rotated.BoundingBox().ymin, 20, places=5)
        self.assertAlmostEqual(rotated.BoundingBox().zmin, 30, places=5)

    def test_multisolid_mesh_mapping(self):
        value = script_spec("""
result = cq.Compound.makeCompound([
    cq.Workplane('XY').box(4,6,8,centered=(True,True,False)).val(),
    cq.Workplane('XY').box(4,6,8,centered=(True,True,False)).translate((20,0,0)).val()
])
""")
        preview = make_preview(build_shape(value, 2))
        self.assertEqual(preview["solids"], 2)
        mapping = preview["triangleSolids"]
        self.assertEqual(len(mapping), len(preview["triangles"]))
        self.assertEqual(set(mapping), {0, 1})
        vertices_by_solid = [set(), set()]
        for triangle, solid_index in zip(preview["triangles"], mapping):
            self.assertEqual(len(triangle), 3)
            for index in triangle:
                self.assertGreaterEqual(index, 0)
                self.assertLess(index, len(preview["vertices"]))
                vertices_by_solid[solid_index].add(index)
        self.assertFalse(vertices_by_solid[0] & vertices_by_solid[1])
        # Each selectable solid must contain all of one physical box, with no
        # triangles accidentally assigned from its disconnected neighbor.
        x_bounds = sorted((min(preview["vertices"][i][0] for i in indices),
                           max(preview["vertices"][i][0] for i in indices))
                          for indices in vertices_by_solid)
        self.assertEqual(x_bounds, [(-2, 2), (18, 22)])
        self.assert_part_ownership(preview)
        self.assertEqual([part["name"] for part in preview["parts"]], ["Part 1", "Part 2"])
        for solid_index, expected_x in enumerate([(-2, 2), (18, 22)]):
            coordinates = [edge[axis] for edge, owner in zip(preview["edges"], preview["edgeSolids"])
                           if owner == solid_index for axis in [0, 3]]
            self.assertEqual((min(coordinates), max(coordinates)), expected_x)

    def test_examples_export_and_step_roundtrip(self):
        import cadquery as cq
        for example in sorted((ROOT / "Examples").glob("*.json")):
            with self.subTest(example=example.name), tempfile.TemporaryDirectory() as directory:
                result = run(example, Path(directory), 4)
                restored = cq.importers.importStep(result["stepPath"]).val()
                self.assertTrue(restored.isValid())
                self.assertAlmostEqual(restored.Volume(), result["volume"], places=3)
                self.assertEqual(len(restored.Solids()), result["solids"])
                self.assertEqual(result["threads"], 4)
                self.assertGreater(len(result["vertices"]), 10)
                self.assertGreater(len(result["triangles"]), 10)
                self.assertEqual(len(result["triangleSolids"]), len(result["triangles"]))
                self.assertEqual(set(result["triangleSolids"]), set(range(result["solids"])))
                self.assertGreater(len(result["edges"]), 10)
                self.assert_part_ownership(result)
                self.assertTrue((Path(directory) / "result.json").is_file())
                self.assertIn("ISO-10303-21", Path(result["stepPath"]).read_text())
                # Consistent outward winding matters for face culling in SceneKit.
                signed_volume = 0
                vertices = result["vertices"]
                for triangle in result["triangles"]:
                    a, b, c = [vertices[index] for index in triangle]
                    signed_volume += (a[0]*(b[1]*c[2]-b[2]*c[1]) + a[1]*(b[2]*c[0]-b[0]*c[2]) + a[2]*(b[0]*c[1]-b[1]*c[0])) / 6
                self.assertGreater(signed_volume, 0)
                self.assertAlmostEqual(signed_volume / result["volume"], 1, delta=0.015)

    def test_cli_errors_are_actionable(self):
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "bad.json"
            request.write_text(json.dumps(script_spec("raise ValueError(\"invalid radius\")")))
            command = [sys.executable, str(ROOT / "Engine" / "worker.py"), "--request", str(request), "--output", directory]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Python design at line 1: ValueError: invalid radius", result.stderr)
            self.assertFalse((Path(directory) / "model.step").exists())


class MeasurementTests(unittest.TestCase):
    def native_operation(self, folder, shape, payload):
        from worker import write_brep
        write_brep(shape, folder / 'source.brep')
        request = folder / 'request.json'
        request.write_text(json.dumps({'brepAsset': 'source.brep', **payload}))
        with (mock.patch('worker.build_shape', side_effect=AssertionError('No program replay')),
              mock.patch('worker.make_preview', side_effect=AssertionError('No tessellation'))):
            return run(request, folder, 4)

    def metric(self, report, identity):
        return next(item['values'] for item in report['metrics'] if item['id'] == identity)

    def test_exact_topology_maps_display_elements_and_survives_native_serialization(self):
        import cadquery as cq
        from worker import read_brep, write_brep
        box = cq.Solid.makeBox(3, 4, 5).rotate((0, 0, 0), (0, 0, 1), 30).translate((-8, 4, 2))
        cylinder = cq.Solid.makeCylinder(2, 7).translate((15, 8, 3))
        shape = cq.Compound.makeCompound([box, cylinder])
        preview = make_preview(shape)
        topology = preview['topology']
        self.assertEqual(len(preview['triangleFaces']), len(preview['triangles']))
        self.assertEqual(len(preview['edgeFeatures']), len(preview['edges']))
        for owner, face_index in zip(preview['triangleSolids'], preview['triangleFaces']):
            self.assertEqual(topology['faces'][face_index]['id']['solidIndex'], owner)
        for segment, owner, edge_index in zip(preview['edges'], preview['edgeSolids'], preview['edgeFeatures']):
            edge = topology['edges'][edge_index]
            self.assertEqual(edge['id']['solidIndex'], owner)
            self.assertTrue(any(segment == a + b for a, b in zip(edge['polyline'], edge['polyline'][1:])))
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            write_brep(shape, folder / 'source.brep')
            restored = read_brep({'brepAsset': 'source.brep'}, folder, cq, 2)
            for item in topology['vertices']:
                identity = item['id']
                vertex = restored.Solids()[identity['solidIndex']].Vertices()[identity['localIndex']]
                for actual, expected in zip(vertex.toTuple(), item['position']):
                    self.assertAlmostEqual(actual, expected, places=10)
            for item in topology['edges']:
                identity = item['id']
                edge = restored.Solids()[identity['solidIndex']].Edges()[identity['localIndex']]
                self.assertEqual(edge.geomType(), item['type'])
                self.assertAlmostEqual(edge.Length(), item['length'], places=10)
            for item in topology['faces']:
                identity = item['id']
                face = restored.Solids()[identity['solidIndex']].Faces()[identity['localIndex']]
                self.assertEqual(face.geomType(), item['type'])
                self.assertAlmostEqual(face.Area(), item['area'], places=10)
        circles = [item for item in topology['edges'] if item['type'] == 'CIRCLE']
        self.assertEqual(len(circles), 2)
        for circle in circles:
            self.assertAlmostEqual(circle['radius'], 2)
            self.assertAlmostEqual(circle['diameter'], 4)
            self.assertAlmostEqual(circle['sweepDegrees'], 360)
            self.assertTrue(circle['closed'])
            self.assertAlmostEqual(circle['center'][0], 15)
            self.assertAlmostEqual(circle['center'][1], 8)
        cylinder_face = next(item for item in topology['faces'] if item['type'] == 'CYLINDER')
        self.assertAlmostEqual(cylinder_face['radius'], 2)
        self.assertAlmostEqual(cylinder_face['area'], 28 * math.pi)
        self.assertAlmostEqual(topology['parts'][0]['volume'], 60)

    def test_partial_circle_and_cone_properties_are_analytic(self):
        import cadquery as cq
        half = cq.Solid.makeCylinder(3, 4, angleDegrees=180)
        preview = make_preview(half)
        arc = next(item for item in preview['topology']['edges'] if item['type'] == 'CIRCLE')
        self.assertAlmostEqual(arc['sweepDegrees'], 180)
        self.assertAlmostEqual(arc['length'], 3 * math.pi)
        self.assertFalse(arc['closed'])
        cone = cq.Solid.makeCone(3, 1, 4)
        face = next(item for item in make_preview(cone)['topology']['faces'] if item['type'] == 'CONE')
        self.assertNotIn('radius', face, 'A cone has no single constant radius')
        self.assertAlmostEqual(face['semiAngleDegrees'], math.degrees(math.atan(0.5)))

    def test_curved_surface_minimum_distance_uses_native_extrema_not_preview_triangles(self):
        import cadquery as cq
        sphere = cq.Solid.makeSphere(2, angleDegrees1=-90, angleDegrees2=90)
        box = cq.Solid.makeBox(1, 1, 1).translate((10, 0, 0))
        shape = cq.Compound.makeCompound([sphere, box])
        vertex_index = next(index for index, vertex in enumerate(box.Vertices())
                            if vertex.toTuple() == (10.0, 0.0, 0.0))
        features = [{'kind': 'face', 'solidIndex': 0, 'localIndex': 0},
                    {'kind': 'vertex', 'solidIndex': 1, 'localIndex': vertex_index}]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with mock.patch.object(cq.exporters, 'export', side_effect=AssertionError('No STEP during measurement')):
                report = self.native_operation(folder, shape, {'operation': 'measure', 'features': features, 'solidIndices': []})
            self.assertAlmostEqual(self.metric(report, 'pair:distance')[0], 8, places=9)
            for actual, expected in zip(self.metric(report, 'pair:delta'), [8, 0, 0]):
                self.assertAlmostEqual(actual, expected, places=9)
            self.assertEqual(report['features'], features)
            self.assertFalse((folder / 'model.step').exists())
            self.assertFalse((folder / 'model.brep').exists())

    def test_trimmed_face_distance_and_line_plane_angles_are_unambiguous(self):
        import cadquery as cq
        a = cq.Solid.makeBox(2, 3, 4)
        b = cq.Solid.makeBox(2, 3, 4).translate((5, 0, 0))
        shape = cq.Compound.makeCompound([a, b])
        x_max = next(index for index, face in enumerate(a.Faces()) if face.normalAt().x > .99)
        x_min = next(index for index, face in enumerate(b.Faces()) if face.normalAt().x < -.99)
        features = [{'kind': 'face', 'solidIndex': 0, 'localIndex': x_max},
                    {'kind': 'face', 'solidIndex': 1, 'localIndex': x_min}]
        with tempfile.TemporaryDirectory() as directory:
            report = self.native_operation(Path(directory), shape, {'operation': 'measure', 'features': features})
            self.assertAlmostEqual(self.metric(report, 'pair:distance')[0], 3)
            self.assertAlmostEqual(self.metric(report, 'pair:angle')[0], 0)
        x_edge = next(index for index, edge in enumerate(a.Edges()) if abs(edge.tangentAt().x) > .99)
        features[0] = {'kind': 'edge', 'solidIndex': 0, 'localIndex': x_edge}
        with tempfile.TemporaryDirectory() as directory:
            report = self.native_operation(Path(directory), shape, {'operation': 'measure', 'features': features})
            self.assertAlmostEqual(self.metric(report, 'pair:angle')[0], 90)

    def test_selected_step_exports_only_requested_exact_solids_in_original_coordinates(self):
        import cadquery as cq
        solids = [cq.Solid.makeBox(1, 2, 3).translate((-10, 3, 4)),
                  cq.Solid.makeBox(2, 3, 4).translate((20, -5, 6)),
                  cq.Solid.makeCylinder(2, 5).translate((40, 8, -3))]
        shape = cq.Compound.makeCompound(solids)
        for selected in ([1], [0, 2]):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                report = self.native_operation(Path(directory), shape, {'operation': 'export', 'solidIndices': selected})
                exported = cq.importers.importStep(report['stepPath']).val()
                self.assertEqual(len(exported.Solids()), len(selected))
                self.assertAlmostEqual(exported.Volume(), sum(solids[index].Volume() for index in selected), places=7)
                for actual, index in zip(exported.Solids(), selected):
                    for coordinate, expected in zip(actual.Center().toTuple(), solids[index].Center().toTuple()):
                        self.assertAlmostEqual(coordinate, expected, places=7)

    def test_selection_operations_reject_invalid_indices_and_topology(self):
        import cadquery as cq
        shape = cq.Solid.makeBox(1, 2, 3)
        for selected in ([], [-1], [1], [True], [0, 0], ['0']):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ModelError):
                    self.native_operation(Path(directory), shape, {'operation': 'export', 'solidIndices': selected})
        invalid = [{'kind': 'face', 'solidIndex': 0, 'localIndex': 999},
                   {'kind': 'edge', 'solidIndex': True, 'localIndex': 0},
                   {'kind': 'surface', 'solidIndex': 0, 'localIndex': 0}]
        for feature in invalid:
            with self.subTest(feature=feature), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ModelError):
                    self.native_operation(Path(directory), shape, {'operation': 'measure', 'features': [feature], 'solidIndices': [0]})


if __name__ == "__main__":
    unittest.main()
