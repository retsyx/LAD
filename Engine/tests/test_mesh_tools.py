"""Exercise immutable iterative calls through the real worker file boundary."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from agent_server import TOOLS,INSTRUCTIONS
from mesh_tools import open_reference,read_asset,_dependencies
from worker import run


def box_mesh():
    return {"vertices":[[0,0,0],[2,0,0],[2,3,0],[0,3,0],[0,0,4],[2,0,4],[2,3,4],[0,3,4]],
            "triangles":[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]}


class WorkerCalls:
    """Stage each call like the app: a context travels with the binary
    reference geometry its open_reference call published."""
    def __init__(self,root):self.root=Path(root);self.index=0;self.references={}
    def call(self,operation,options=None,**assets):
        folder=self.root/str(self.index);self.index+=1;folder.mkdir()
        request={"operation":"mesh_"+operation,"options":options or {}}
        for key,value in assets.items():
            suffix=".stl" if key=="sourceAsset" and isinstance(value,bytes) else ".json"
            filename=key+suffix
            (folder/filename).write_bytes(value if isinstance(value,bytes) else json.dumps(value).encode())
            request[key]=filename
        context=assets.get("contextAsset")
        if isinstance(context,dict) and context.get("id") in self.references:
            (folder/"reference.npz").write_bytes(self.references[context["id"]].read_bytes())
            request["referenceAsset"]="reference.npz"
        path=folder/"request.json";path.write_text(json.dumps(request))
        metadata=run(path,folder,2,defer_step=True)
        record=json.loads((folder/"mesh-record.json").read_text())
        if operation=="open_reference" and record.get("status")=="ok":
            self.references[record["payload"]["context"]["id"]]=folder/"mesh-reference.npz"
        return metadata,record,folder


class IterativeMeshToolTests(unittest.TestCase):
    def test_joint_fit_cad_pins_are_checked_inside_evidence_dependencies(self):
        context={"id":"ctx","source_hash":"original"};current={"id":"r2","geometry_hash":"g2"}
        mesh_only={"context_ref":"ctx","source_hash":"original","based_on_revision":None,
                   "dependencies":{"evidence_dependencies":[{"source_hash":"original","context_ref":"ctx"}]}}
        _dependencies(mesh_only,context,current)
        cad_fit=copy.deepcopy(mesh_only)
        cad_fit["dependencies"]["evidence_dependencies"][0]["cad_revision"]="r1"
        with self.assertRaisesRegex(ValueError,"STALE_DEPENDENCY"):_dependencies(cad_fit,context,current)
        cad_fit=copy.deepcopy(mesh_only);cad_fit["based_on_revision"]="r1"
        with self.assertRaisesRegex(ValueError,"STALE_DEPENDENCY"):_dependencies(cad_fit,context,current)

    def test_discovery_replaces_old_pipeline_and_defines_all_services(self):
        names={item[0] for item in TOOLS}
        expected={"lad_mesh_"+name for name in ["open_reference","inspect","fit","try_edit","compare","commit","undo","redo","branch","set_delivery","export_step"]}
        self.assertTrue(expected<=names)
        self.assertFalse({"lad_mesh_analyze","lad_mesh_propose","lad_mesh_evaluate","lad_mesh_assemble"}&names)
        self.assertIn("completion obligations",INSTRUCTIONS)
        self.assertIn("meshAPIHelpPath",INSTRUCTIONS)

    def test_geometry_file_admission_keeps_large_ascii_references_and_rejects_oversize_files(self):
        # Sparse files exercise admission without allocating or reading their
        # contents. ASCII STL can exceed the old 128 MB cap within the triangle
        # budget; the worker shares the app's 512 MB geometry-file ceiling.
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"source.stl"
            with path.open("wb") as stream:stream.truncate(128_000_001)
            self.assertEqual(read_asset(directory,"source.stl"),path)
            # Earlier in-process worker calls can already have installed their
            # hard 512 MB file limit. Exercise oversize admission through stat
            # metadata without trying to exceed that process-wide limit.
            info=list(path.lstat());info[6]=512_000_001
            with mock.patch.object(Path,"lstat",return_value=os.stat_result(info)):
                with self.assertRaisesRegex(ValueError,"bounded regular private files"):
                    read_asset(directory,"source.stl")

    def test_unit_normalization_preserves_source_and_bounds_rounding(self):
        from fractions import Fraction
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"source.json";path.write_text(json.dumps(box_mesh()))
            original=path.read_bytes()
            context,r0=open_reference(path,units="in",max_deviation=.01)
            self.assertEqual(context["units"],"mm")
            self.assertEqual(context["source_units"],"in")
            self.assertEqual(context["original_vertices"].tolist(),box_mesh()["vertices"])
            for before,after in zip(box_mesh()["vertices"],context["vertices"]):
                exact=[Fraction(v)*Fraction(127,5) for v in before]
                error=sum(float(abs(Fraction.from_float(a)-b))**2 for a,b in zip(after,exact))**.5
                self.assertLessEqual(error,context["conversion_arithmetic_margin"])
            self.assertLessEqual(Fraction.from_float(context["max_deviation"]),Fraction.from_float(.01)*Fraction(127,5))
            self.assertEqual(r0["body_ids"],[])
            self.assertIsNone(r0["geometry_hash"])
            self.assertEqual(path.read_bytes(),original)

    def test_worker_keeps_immutable_evidence_and_body_free_construction(self):
        with tempfile.TemporaryDirectory() as directory:
            calls=WorkerCalls(directory)
            metadata,opened,_=calls.call("open_reference",options={"units":"mm","max_deviation":.03},sourceAsset=box_mesh())
            self.assertEqual(opened["status"],"ok",opened)
            self.assertNotIn('"vertices": [',json.dumps(metadata))
            context=opened["payload"]["context"];revision=opened["payload"]["revision"]
            before=copy.deepcopy(context)
            _,inspected,_=calls.call("inspect",contextAsset=context,revisionAsset=revision,queryAsset={"kind":"section","scope":"all","plane":{"origin":[0,0,2],"normal":[0,0,1]}})
            self.assertIn(inspected["status"],["ok","partial"])
            self.assertTrue(inspected["payload"]["sections"])
            _,preview,folder=calls.call("try_edit",contextAsset=context,revisionAsset=revision,editAsset={"kind":"construction","operation":"add","construction_id":"axis-main","tool":{"family":"axis","geometry":{"origin":[1,1.5,0],"direction":[0,0,1]}}})
            self.assertIsNotNone(preview["payload"],preview)
            self.assertTrue(preview["payload"]["commit_eligible"],preview)
            self.assertEqual(preview["payload"]["body_ids"],[])
            self.assertEqual(preview["payload"]["quick_comparison"]["after"]["acceptance"],"not_evaluated")
            self.assertFalse((folder/"model.brep").exists())
            self.assertEqual(context,before)

    def test_reference_geometry_travels_once_as_binary_arrays(self):
        import struct
        mesh=box_mesh()
        stl=bytearray(80)+struct.pack("<I",len(mesh["triangles"]))
        for triangle in mesh["triangles"]:
            stl+=struct.pack("<12fH",0,0,0,*[value for index in triangle for value in mesh["vertices"][index]],0)
        with tempfile.TemporaryDirectory() as directory:
            calls=WorkerCalls(directory)
            _,opened,folder=calls.call("open_reference",options={"units":"cm","max_deviation":.01},sourceAsset=bytes(stl))
            self.assertEqual(opened["status"],"ok",opened)
            context=opened["payload"]["context"]
            for key in ("vertices","triangles","original_vertices"):self.assertNotIn(key,context)
            self.assertEqual(context["geometry"]["triangle_count"],12)
            self.assertEqual(context["geometry"]["vertex_count"],36,"Binary STL facets keep their own corners")
            with np.load(folder/"mesh-reference.npz",allow_pickle=False) as arrays:
                self.assertEqual(set(arrays.files),{"vertices","triangles","original_vertices"})
                np.testing.assert_array_equal(arrays["original_vertices"][:3],[mesh["vertices"][i] for i in mesh["triangles"][0]])
                np.testing.assert_allclose(arrays["vertices"],arrays["original_vertices"]*10)
            # Later calls read the staged binary reference, never the JSON context.
            _,inspected,_=calls.call("inspect",contextAsset=context,revisionAsset=opened["payload"]["revision"],
                                     queryAsset={"kind":"select","source_triangles":[0,1]})
            self.assertIn(inspected["status"],["ok","partial"],inspected)

    def test_edits_from_one_revision_reuse_its_base_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            calls=WorkerCalls(directory)
            _,opened,_=calls.call("open_reference",options={"units":"mm","max_deviation":.03},sourceAsset=box_mesh())
            context=opened["payload"]["context"];revision=opened["payload"]["revision"]
            edit={"kind":"construction","operation":"add","construction_id":"axis-main","tool":{"family":"axis","geometry":{"origin":[1,1.5,0],"direction":[0,0,1]}}}
            _,first,_=calls.call("try_edit",contextAsset=context,revisionAsset=revision,editAsset=edit)
            base=first["payload"]["base_comparison"]
            self.assertEqual(first["payload"]["quick_comparison"]["before_comparison_id"],base["comparison_id"])
            self.assertEqual(first["payload"]["quick_comparison"]["cache_reuse"],"base comparison computed")
            _,second,_=calls.call("try_edit",contextAsset=context,revisionAsset=revision,editAsset=edit,baseComparisonAsset=base)
            self.assertNotIn("base_comparison",second["payload"])
            self.assertEqual(second["payload"]["quick_comparison"]["before_comparison_id"],base["comparison_id"])
            self.assertEqual(second["payload"]["quick_comparison"]["cache_reuse"],"base comparison reused")
            # A report that does not match the base revision is recomputed.
            altered=dict(base,model_ref="another-revision")
            _,third,_=calls.call("try_edit",contextAsset=context,revisionAsset=revision,editAsset=edit,baseComparisonAsset=altered)
            self.assertEqual(third["payload"]["quick_comparison"]["cache_reuse"],"base comparison computed")
            coverage=base["geometry"]["mesh_to_cad"]["coverage"]
            self.assertNotIn("unprocessed_triangle_ids",coverage)
            self.assertEqual(sum(last-first+1 for first,last in coverage["unprocessed_triangle_ranges"]),coverage["unprocessed_triangle_count"])

    def test_script_worker_runs_mesh_tools_without_loading_itself_again(self):
        # Run as a script, the worker module is __main__. A mesh edit must use
        # that module's CAD pipeline rather than import worker.py again as a
        # second copy with its own module-level state.
        with tempfile.TemporaryDirectory() as directory:
            calls=WorkerCalls(directory)
            _,opened,_=calls.call("open_reference",options={"units":"mm","max_deviation":.03},sourceAsset=box_mesh())
            self.assertEqual(opened["status"],"ok",opened)
            context=opened["payload"]["context"]
            folder=Path(directory)/"script";folder.mkdir()
            request={"operation":"mesh_try_edit","options":{},"referenceAsset":"reference.npz"}
            for key,value in {"contextAsset":context,"revisionAsset":opened["payload"]["revision"],
                              "editAsset":{"kind":"body","operation":"create","body_id":"body-main",
                                           "tool":{"family":"box","geometry":{"origin":[0,0,0],"size":[2,3,4]}}}}.items():
                (folder/(key+".json")).write_text(json.dumps(value));request[key]=key+".json"
            (folder/"reference.npz").write_bytes(calls.references[context["id"]].read_bytes())
            (folder/"request.json").write_text(json.dumps(request))
            # -X importtime reports every module the process imports by name.
            process=subprocess.run([sys.executable,"-X","importtime",str(Path(__file__).resolve().parents[1]/"worker.py"),
                                    "--request",str(folder/"request.json"),"--output",str(folder),"--threads","1","--defer-step"],
                                   capture_output=True,text=True,timeout=300)
            self.assertEqual(process.returncode,0,process.stderr[-4000:])
            imported={line.rsplit("|",1)[1].strip() for line in process.stderr.splitlines() if line.startswith("import time:")}
            self.assertTrue("mesh_tools" in imported,"The request did not reach the mesh tools")
            self.assertFalse("worker" in imported,"Mesh tools imported a second copy of worker.py")
            result=json.loads((folder/"mesh-result.json").read_text())
            self.assertTrue(result["native_preview"],result)

    def test_invalid_input_is_structured_without_delivered_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/"request.json"
            path.write_text(json.dumps({"operation":"mesh_open_reference","sourceAsset":"../source.stl","options":{"units":"mm","max_deviation":.1}}))
            result=run(path,root,1,True)
            self.assertEqual(result["status"],"error")
            self.assertIsNone(result["payload"])
            self.assertFalse((root/"model.brep").exists())
            (root/"file.json").write_text("{}")
            (root/"link.json").symlink_to(root/"file.json")
            with self.assertRaises(ValueError):read_asset(root,"link.json")

    def test_private_dense_stl_can_start_from_local_sphere_evidence(self):
        supplied=os.environ.get("LAD_MESH_HOLDER_STL")
        if not supplied:self.skipTest("Set LAD_MESH_HOLDER_STL for the private original-source workflow")
        source=Path(supplied);original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            calls=WorkerCalls(directory)
            _,opened,_=calls.call("open_reference",options={"units":"mm","max_deviation":.03,"source_kind":"cad_tessellation"},sourceAsset=original)
            self.assertEqual(opened["status"],"ok",opened)
            context=opened["payload"]["context"];revision=opened["payload"]["revision"]
            self.assertGreater(len(context["triangles"]),12_000)
            vertices=np.asarray(context["vertices"]);triangles=np.asarray(context["triangles"])
            selected=np.flatnonzero(np.max(np.abs(np.linalg.norm(vertices[triangles],axis=2)-50),axis=1)<1e-4).tolist()
            self.assertGreater(len(selected),100)
            _,inspected,_=calls.call("inspect",contextAsset=context,revisionAsset=revision,queryAsset={"kind":"select","source_triangles":selected})
            self.assertIn(inspected["status"],["ok","partial"],inspected)
            _,fitted,_=calls.call("fit",options={"families":["sphere"]},contextAsset=context,revisionAsset=revision,evidenceAsset=[inspected["payload"]])
            self.assertTrue(fitted["payload"],fitted)
            candidate=fitted["payload"][0]
            _,preview,_=calls.call("try_edit",contextAsset=context,revisionAsset=revision,fitsAsset=[candidate],
                                 editAsset={"kind":"body","operation":"create","target_body":"outer-sphere","tool":{"fit_candidate":candidate["id"]}})
            self.assertIsNotNone(preview["payload"],preview)
            self.assertTrue(preview["payload"]["commit_eligible"],preview)
            self.assertEqual(preview["payload"]["quick_comparison"]["after"]["acceptance"],"not_evaluated")
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),digest)


if __name__=="__main__":unittest.main()
