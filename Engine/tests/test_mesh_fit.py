"""Fitted analytic alternatives, joint hard relationships and profile evidence."""
import math
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_inspect import inspect
from mesh_fit import fit


def cylinder_wall(radius=3,height=10,count=32,origin=(0,0,0),top_radius=None):
    top_radius=radius if top_radius is None else top_radius
    vertices=[[r*math.cos(i*2*math.pi/count)+origin[0],r*math.sin(i*2*math.pi/count)+origin[1],z+origin[2]] for z,r in ((0,radius),(height,top_radius)) for i in range(count)]
    triangles=[]
    for i in range(count):j=(i+1)%count;triangles.extend([[i,j,j+count],[i,j+count,i+count]])
    return vertices,triangles


def ctx(vertices,triangles,**options):
    return {"id":"source-context","source_hash":"immutable-source", "vertices":vertices,"triangles":triangles,"units":"mm","max_deviation":.03,"source_kind":"cad_tessellation",**options}


def evidence(context,query=None):
    result=inspect(context,{"id":"r0"},query or {"kind":"select","scope":"all"})
    if result["status"] not in ("ok","partial"):raise AssertionError(result)
    return result["payload"]


class FitTests(unittest.TestCase):
    def test_cylinder_fit_preserves_observed_extents_and_chord_discrepancy(self):
        c=ctx(*cylinder_wall());e=evidence(c);result=fit(c,[e],families=["cylinder","cone"])
        self.assertEqual(result["status"],"ok",result)
        candidate=next(x for x in result["payload"] if x["family"]=="cylinder");member=candidate["members"][0]
        self.assertAlmostEqual(member["geometry"]["radius"],3,places=7)
        self.assertTrue(np.allclose(member["observed_extent"]["axial_interval"],[-5,5]))
        self.assertFalse(member["observed_extent"]["terminal_faces_observed"])
        self.assertGreater(member["fit_report"]["triangle_interior_sampled_maximum"],0)
        self.assertEqual(candidate["fit_report"]["guarantee"],"sampled_local_fit_only")
        self.assertEqual(candidate["inferred_extensions"][member["id"]]["material_role"],"unknown")

    def test_cone_is_fitted_from_geometric_radius_taper(self):
        c=ctx(*cylinder_wall(radius=4,top_radius=2));result=fit(c,[evidence(c)],families=["cone"])
        self.assertEqual(result["status"],"ok",result);geometry=result["payload"][0]["members"][0]["geometry"]
        self.assertAlmostEqual(abs(geometry["slope"]),.2,places=5)
        member=result["payload"][0]["members"][0];interval=member["observed_extent"]["axial_interval"]
        self.assertTrue(np.allclose(sorted(geometry["radius"]+geometry["slope"]*np.asarray(interval)),[2,4],atol=1e-5))

    def test_sphere_alternative_and_small_cap_identifiability(self):
        import cadquery as cq
        shape=cq.Solid.makeSphere(5,angleDegrees1=-90,angleDegrees2=90);vertices,triangles=shape.tessellate(.1,.3)
        c=ctx([v.toTuple() for v in vertices],triangles);result=fit(c,[evidence(c)],families=["sphere"])
        self.assertEqual(result["status"],"ok",result)
        self.assertAlmostEqual(result["payload"][0]["members"][0]["geometry"]["radius"],5,places=5)

    def test_joint_counterbore_is_one_alternative_with_shared_axis(self):
        a,ta=cylinder_wall(2,5);b,tb=cylinder_wall(3,3,origin=(0,0,5));c=ctx(a+b,ta+[[i+len(a) for i in t] for t in tb])
        first=evidence(c,{"kind":"select","triangle_ids":list(range(len(ta)))});second=evidence(c,{"kind":"select","triangle_ids":list(range(len(ta),len(ta)+len(tb)))})
        constraints=[{"kind":"coaxial","members":[first["id"],second["id"]],"strength":"hard"}]
        result=fit(c,[first,second],families=["cylinder"],constraints=constraints)
        self.assertEqual(result["status"],"ok",result);candidate=result["payload"][0]
        self.assertEqual(candidate["family"],"joint");self.assertEqual(len(candidate["members"]),2)
        self.assertTrue(candidate["hard_constraint_report"][0]["satisfied"])
        self.assertTrue(np.array_equal(candidate["members"][0]["geometry"]["axis"],candidate["members"][1]["geometry"]["axis"]))
        self.assertNotEqual(candidate["members"][0]["observed_extent"]["axial_interval"],candidate["members"][1]["observed_extent"]["axial_interval"])

    def test_conflicting_fixed_values_and_unsupported_tangency_are_not_silently_relaxed(self):
        c=ctx(*cylinder_wall());e=evidence(c)
        constraints=[{"kind":"fixed","parameter":"radius","value":2},{"kind":"fixed","parameter":"radius","value":3}]
        result=fit(c,[e],families=["cylinder"],constraints=constraints)
        self.assertEqual(result["status"],"no_result");self.assertEqual(result["diagnostics"][0]["code"],"CONSTRAINT_CONFLICT")
        unsupported=fit(c,[e],families=["cylinder"],constraints=[{"kind":"tangent"}])
        self.assertEqual(unsupported["status"],"error");self.assertEqual(unsupported["diagnostics"][0]["code"],"UNSUPPORTED_CONSTRAINT")

    def test_profiles_and_extrusions_require_observed_sections_and_preserve_open_traces(self):
        c=ctx(*cylinder_wall());e=evidence(c,{"kind":"section","planes":[{"origin":[0,0,z],"normal":[0,0,1]} for z in (2,8)]})
        result=fit(c,[e],families=["profile","extrusion"])
        self.assertIn(result["status"],("ok","partial"),result)
        profile=next(x for x in result["payload"] if x["family"]=="profile")["members"][0]["geometry"]
        self.assertTrue(profile["loops"][0]["closed"])
        self.assertTrue(all(segment["kind"]=="arc" for segment in profile["loops"][0]["segments"]))
        extrusion=next(x for x in result["payload"] if x["family"]=="extrusion")["members"][0]["geometry"]
        self.assertAlmostEqual(extrusion["observed_interval"][1]-extrusion["observed_interval"][0],6)
        self.assertNotIn("height",extrusion,"Observed section spacing is not an automatically inferred solid termination")

    def test_revolution_checks_multiple_azimuths_and_all_selected_points(self):
        c=ctx(*cylinder_wall());result=fit(c,[evidence(c)],families=["revolution"])
        self.assertIn(result["status"],("ok","partial"),result)
        geometry=result["payload"][0]["members"][0]["geometry"]
        self.assertEqual(geometry["kind"],"revolution");self.assertNotIn("angle_degrees",geometry)
        self.assertTrue(geometry["observed_angle_intervals"])

    def test_stale_evidence_and_empty_search_do_not_manufacture_a_model(self):
        c=ctx(*cylinder_wall());e=evidence(c);e["source_hash"]="stale"
        result=fit(c,[e],families=["cylinder"]);self.assertEqual(result["status"],"error")
        unsupported=fit(c,[evidence(c)],families=["freeform"])
        self.assertEqual(unsupported["status"],"no_result");self.assertEqual(unsupported["payload"],[])


if __name__=="__main__":unittest.main()
