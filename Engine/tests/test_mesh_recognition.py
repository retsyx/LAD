"""Optional regional recognizers produce reusable alternatives, never solids."""
import copy
import hashlib
import math
import os
from pathlib import Path
import sys
import unittest

import numpy as np
import cadquery as cq

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_inspect import inspect
from mesh_fit import fit
from mesh_tools import open_reference


def context(mesh):
    return {"id":"recognition-context","source_hash":hashlib.sha256(repr(mesh).encode()).hexdigest(),"units":"mm","max_deviation":.03,"source_kind":"cad_tessellation",**mesh}


def mesh_for(shape):
    vertices,triangles=shape.tessellate(.08,.15)
    return {"vertices":[v.toTuple() for v in vertices],"triangles":triangles}


def screw_mesh(pitch=4.,rotation=None,translation=None):
    vertices=[];faces=[];count=128;period=abs(pitch)
    p0,p1,p2,p3=(period*.125,period*.375,period*.625,period*.875)
    for ra,rb,pa,pb in [(8,10,p0,p1),(10,10,p1,p2),(10,8,p2,p3)]:
        base=len(vertices)
        for i in range(count+1):
            angle=6*math.pi*i/count
            for radius,phase in [(ra,pa),(rb,pb)]:
                vertices.append([radius*math.cos(angle),radius*math.sin(angle),pitch*angle/(2*math.pi)+phase])
        for i in range(count):
            a=base+2*i;faces.extend([[a,a+2,a+3],[a,a+3,a+1]])
    points=np.asarray(vertices)
    if rotation is not None:points=points@np.asarray(rotation).T
    if translation is not None:points+=translation
    return {"vertices":points.tolist(),"triangles":faces}


class RecognitionTests(unittest.TestCase):
    def recognize(self,c,families="auto",**query):
        result=inspect(c,{"id":"empty-r0"},{"kind":"recognize","scope":"all","families":families,**query})
        self.assertIn(result["status"],("ok","partial"),result)
        return result["payload"]

    def test_tangent_torus_patch_retains_own_original_support_and_yields_fitted_member(self):
        shape=(cq.Workplane("XZ").moveTo(6,0).lineTo(12,0).lineTo(12,2)
               .radiusArc((10,4),-2).lineTo(6,4).close().revolve(360,(0,0),(0,1)).val())
        c=context(mesh_for(shape));before=copy.deepcopy(c)
        evidence=self.recognize(c,["torus"])
        entries=evidence["recognition_records"];self.assertTrue(entries)
        self.assertTrue(evidence["recognition_unknown_triangle_ids"])
        for entry in entries:
            geometry=entry["geometry"]
            self.assertAlmostEqual(geometry["major_radius"],10,places=5)
            self.assertAlmostEqual(geometry["minor_radius"],2,places=5)
            self.assertAlmostEqual(geometry["center"][2],2,places=5)
            self.assertLess(entry["fit_report"]["source_vertex_maximum"],1e-5)
            self.assertLess(len(entry["triangle_ids"]),len(c["triangles"]))
        fitted=fit(c,[evidence],families=["torus"])
        self.assertTrue(fitted["payload"],fitted)
        member=fitted["payload"][0]["members"][0]
        self.assertEqual(member["geometry"]["kind"],"torus")
        self.assertEqual(member["inferred_extent"]["material_role"],"unknown")
        self.assertTrue(fitted["payload"][0]["unresolved_evidence"])
        self.assertEqual(c,before)
        later=inspect(c,{"id":"later-r7"},{"kind":"recognize","scope":"all","families":["torus"]})
        self.assertEqual(evidence["id"],later["payload"]["id"])

    def test_signed_pitch_flanks_survive_rotated_translated_frames(self):
        angle=.63;rotation=np.array([[1,0,0],[0,math.cos(angle),-math.sin(angle)],[0,math.sin(angle),math.cos(angle)]])
        for pitch,turn in ((4.,None),(-3.25,rotation)):
            with self.subTest(pitch=pitch):
                c=context(screw_mesh(pitch,turn,[3,-2,5] if turn is not None else None))
                evidence=self.recognize(c,["helical_sweep"])
                self.assertEqual(len(evidence["recognition_records"]),1)
                entry=evidence["recognition_records"][0];geometry=entry["geometry"]
                self.assertAlmostEqual(geometry["pitch"],abs(pitch),places=5)
                self.assertEqual(geometry["handedness"],"right" if pitch>0 else "left")
                self.assertEqual(len(geometry["profile"]["loops"][0]["points"]),4)
                self.assertLess(entry["fit_report"]["source_vertex_maximum"],1e-5)
                self.assertEqual(entry["observed_extent"]["axial_interval"][0],0)
                self.assertGreater(entry["observed_extent"]["axial_interval"][1],2*abs(pitch))
                self.assertTrue(fit(c,[evidence],families=["helical_sweep"])["payload"])

    def test_rounded_opening_and_concentric_shell_remain_distinct_alternatives(self):
        sphere=lambda r:cq.Solid.makeSphere(r,angleDegrees1=-90,angleDegrees2=90)
        shell=sphere(20).cut(sphere(17))
        tool=cq.Workplane("XZ",origin=(0,-25,-5)).rect(8,5).extrude(-25).edges("|Y").fillet(1.25).val()
        c=context(mesh_for(shell.cut(tool).clean()))
        evidence=self.recognize(c,["rounded_rectangle_extrusion","concentric_spherical_shell","sphere"])
        entries=evidence["recognition_records"]
        rounded=next(entry for entry in entries if entry["family"]=="rounded_rectangle_extrusion")
        d=rounded["geometry"]["dimensions"]
        self.assertAlmostEqual(d["width"],8,places=4);self.assertAlmostEqual(d["height"],5,places=4)
        self.assertAlmostEqual(d["corner_radius"],1.25,places=4)
        self.assertEqual(len(rounded["geometry"]["profile"]["loops"][0]["segments"]),8)
        skeleton=next(entry for entry in entries if entry["family"]=="concentric_spherical_shell")
        self.assertAlmostEqual(skeleton["geometry"]["outer_radius"],20,places=4)
        self.assertAlmostEqual(skeleton["geometry"]["inner_radius"],17,places=4)
        a,b=(set(item["triangle_ids"]) for item in skeleton["surface_members"])
        self.assertFalse(a&b);self.assertTrue(a);self.assertTrue(b)
        fitted=fit(c,[evidence],families=["concentric_spherical_shell"])
        self.assertTrue(fitted["payload"],fitted)
        self.assertEqual(len(fitted["payload"][0]["members"]),1)
        self.assertTrue(fitted["payload"][0]["unresolved_evidence"])
        self.assertEqual(set(rounded["triangle_ids"])&(a|b),set())

    def test_scope_clips_and_budget_never_widen_original_support(self):
        c=context(mesh_for(cq.Solid.makeBox(2,3,4)))
        result=inspect(c,{"id":"r0"},{"kind":"recognize","scope":"all","families":["plane"],"recognition_triangle_budget":2})
        self.assertEqual(result["status"],"partial")
        p=result["payload"];self.assertEqual(p["recognition_work"]["processed_triangle_count"],2)
        self.assertTrue(set(range(2,len(c["triangles"])))<=set(p["recognition_unknown_triangle_ids"]))
        selected=inspect(c,{"id":"r0"},{"kind":"select","box":{"min":[0,0,0],"max":[1,1,1],"mode":"clip"}})["payload"]
        clipped=inspect(c,{"id":"r0"},{"kind":"recognize","selection":{"evidence_ref":selected["id"]},"families":["plane"]},lambda _:selected)
        self.assertEqual(clipped["status"],"partial")
        self.assertFalse(clipped["payload"]["recognition_records"])
        self.assertTrue(any(d["code"]=="CLIPPED_RECOGNITION_SCOPE" for d in clipped["diagnostics"]))
        ordinary=inspect(c,{"id":"r0"},{"kind":"select","scope":"all"})["payload"]
        missing=fit(c,[ordinary],families=["torus"])
        self.assertEqual(missing["status"],"no_result")
        self.assertTrue(any(d["code"]=="RECOGNITION_EVIDENCE_REQUIRED" for d in missing["diagnostics"]))

    def test_private_dense_holder_recognition_when_supplied(self):
        supplied=os.environ.get("LAD_MESH_HOLDER_STL")
        if not supplied:self.skipTest("Set LAD_MESH_HOLDER_STL for private dense-holder recognition")
        path=Path(supplied);before=hashlib.sha256(path.read_bytes()).hexdigest()
        c,_=open_reference(path,units="mm",max_deviation=.03,source_kind="cad_tessellation")
        self.assertGreater(len(c["triangles"]),12000)
        evidence=self.recognize(c)
        entries=evidence["recognition_records"]
        self.assertTrue(any(x["family"]=="helical_sweep" and abs(x["geometry"]["pitch"]-4)<.001 for x in entries))
        self.assertTrue(any(x["family"]=="rounded_rectangle_extrusion" and abs(x["geometry"]["dimensions"]["width"]-15)<.01 for x in entries))
        self.assertTrue(any(x["family"]=="concentric_spherical_shell" and abs(x["geometry"]["outer_radius"]-50)<.01 and abs(x["geometry"]["inner_radius"]-45)<.01 for x in entries))
        for major,minor in ((24.5,2.),(23.5,1.)):
            self.assertTrue(any(x["family"]=="torus" and abs(x["geometry"]["major_radius"]-major)<.01 and abs(x["geometry"]["minor_radius"]-minor)<.01 for x in entries))
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),before)

    def test_degenerate_reference_facets_remain_unknown_and_plane_residuals_are_measured(self):
        c=context({"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,1e-8]],"triangles":[[0,1,2],[0,2,3],[0,0,1]]})
        before=copy.deepcopy(c)
        result=inspect(c,{"id":"r0"},{"kind":"recognize","scope":"all","families":["plane"]})
        self.assertEqual(result["status"],"partial",result)
        evidence=result["payload"]
        self.assertIn(2,evidence["recognition_unknown_triangle_ids"])
        self.assertTrue(any(d["code"]=="DEGENERATE_RECOGNITION_SCOPE" for d in result["diagnostics"]))
        plane=evidence["recognition_records"][0]
        self.assertGreater(plane["fit_report"]["source_vertex_maximum"],0)
        self.assertGreater(plane["fit_report"]["triangle_centroid_maximum"],0)
        self.assertEqual(c,before)
        empty=context({"vertices":[[0,0,0],[1,0,0],[2,0,0]],"triangles":[[0,1,2]]})
        only=self.recognize(empty,["plane"])
        self.assertEqual(only["recognition_unknown_triangle_ids"],[0])
        self.assertFalse(only["recognition_records"])

    def test_mixed_evidence_and_unsupported_regional_refinement_are_explicit(self):
        c=context(mesh_for(cq.Solid.makeTorus(10,2)))
        recognized=self.recognize(c,["torus"],role="first")
        ordinary=inspect(c,{"id":"r0"},{"kind":"select","scope":"all"})["payload"]
        for families in ("auto",["torus","plane"]):
            mixed=fit(c,[recognized,ordinary],families=families)
            self.assertEqual(mixed["status"],"no_result")
            self.assertEqual(mixed["payload"],[])
            self.assertTrue(any(d["code"]=="UNSUPPORTED_MIXED_EVIDENCE" and "atomic edit group" in d["message"] for d in mixed["diagnostics"]))
        unchanged=fit(c,[recognized],families=["torus"],constraints=[{"kind":"fixed","parameter":"major_radius","value":10}])
        self.assertTrue(unchanged["payload"],unchanged)
        changed=fit(c,[recognized],families=["torus"],constraints=[{"kind":"fixed","parameter":"major_radius","value":11}])
        self.assertEqual(changed["status"],"no_result")
        self.assertTrue(any(d["code"]=="RECOGNITION_REFIT_UNSUPPORTED" for d in changed["diagnostics"]))
        second=self.recognize(c,["torus"],role="second")
        relational=fit(c,[recognized,second],families=["torus"],constraints=[{"kind":"parallel","members":[recognized["id"],second["id"]]}])
        self.assertEqual(relational["status"],"no_result")
        self.assertTrue(any(d["code"]=="UNSUPPORTED_RECOGNITION_CONSTRAINT" for d in relational["diagnostics"]))


if __name__=="__main__":unittest.main()
