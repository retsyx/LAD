"""Evidence query behavior, physical source identity and clipped provenance."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_inspect import inspect,_analysis


def context(vertices,triangles):
    source={"vertices":vertices,"triangles":triangles}
    return {"id":"ctx-test","source_hash":hashlib.sha256(json.dumps(source).encode()).hexdigest(),**source,"units":"mm","max_deviation":.03,"source_kind":"cad_tessellation"}


def box_context():
    vertices=[[x,y,z] for x,y,z in [(0,0,0),(2,0,0),(2,2,0),(0,2,0),(0,0,2),(2,0,2),(2,2,2),(0,2,2)]]
    triangles=[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
    return context(vertices,triangles)


class InspectTests(unittest.TestCase):
    def setUp(self):self.revision={"id":"r0"}

    def test_empty_revision_source_evidence_is_immutable_and_revision_independent(self):
        c=box_context();before=copy.deepcopy(c);q={"kind":"select","triangle_ids":[0,1]}
        first=inspect(c,self.revision,q);self.assertEqual(first["status"],"ok")
        later=inspect(c,{"id":"r8","_shape":"not accessed by source query"},q)
        self.assertEqual(first["payload"]["id"],later["payload"]["id"])
        self.assertEqual(c,before);self.assertIsNone(first["payload"]["cad_revision"])
        self.assertEqual(first["payload"]["measurements"]["area"],4)

    def test_box_clipping_preserves_original_ids_and_set_algebra_area(self):
        c=context([[0,0,0],[2,0,0],[2,2,0],[0,2,0]],[[0,1,2],[0,2,3]])
        whole=inspect(c,self.revision,{"kind":"select","scope":"all"})["payload"]
        quarter=inspect(c,self.revision,{"kind":"select","box":{"min":[0,0,0],"max":[1,1,0],"mode":"clip"}})["payload"]
        self.assertAlmostEqual(quarter["measurements"]["area"],1)
        self.assertEqual(quarter["source_selection"]["triangle_ids"],[0,1])
        self.assertTrue(all("barycentric_polygons" in member for member in quarter["selection"]["source_members"]))
        records={whole["id"]:whole,quarter["id"]:quarter}
        for operation,area in [("union",4),("intersection",1),("difference",3),("symmetric_difference",3)]:
            result=inspect(c,self.revision,{"kind":"combine","selections":[whole["id"],quarter["id"]],"operation":operation},records.__getitem__)
            self.assertEqual(result["status"],"ok",result)
            self.assertAlmostEqual(result["payload"]["measurements"]["area"],area)

    def test_growth_stops_at_sharp_edges_and_shrink_zero_preserves_selection(self):
        c=box_context();grown=inspect(c,self.revision,{"kind":"grow","seed":{"source_triangle":0},"max_geodesic_distance":100,"barriers":["sharp_feature"]})
        self.assertEqual(grown["payload"]["source_selection"]["triangle_ids"],[0,1])
        self.assertTrue(grown["payload"]["stopped_barriers"])
        record=grown["payload"]
        shrunk=inspect(c,self.revision,{"kind":"shrink","evidence_ref":record["id"],"distance":0},lambda _:record)
        self.assertEqual(shrunk["payload"]["source_selection"],record["source_selection"])

    def test_nonmanifold_crossing_and_degenerate_geometry_are_reported(self):
        c=context([[0,0,0],[1,0,0],[0,1,0],[0,-1,0],[0,0,1],[2,0,0]],[[0,1,2],[1,0,3],[0,1,4],[0,1,5]])
        result=inspect(c,self.revision,{"kind":"grow","seed":{"source_triangle":0},"max_geodesic_distance":100})
        self.assertEqual(result["payload"]["source_selection"]["triangle_ids"],[0])
        self.assertTrue(any(x["reason"]=="nonmanifold_ambiguity" for x in result["payload"]["stopped_barriers"]))
        all_evidence=inspect(c,self.revision,{"kind":"select","scope":"all"})["payload"]
        self.assertEqual(all_evidence["quality_flags"]["degenerate_triangle_ids"],[3])
        self.assertEqual(len(c["triangles"]),4)

    def test_nearest_ray_hit_is_not_first_triangle(self):
        c=context([[0,0,10],[2,0,10],[0,2,10],[0,0,2],[2,0,2],[0,2,2]],[[0,1,2],[3,4,5]])
        result=inspect(c,self.revision,{"kind":"select","ray":{"origin":[.2,.2,0],"direction":[0,0,1]}})
        self.assertEqual(result["payload"]["hit"]["triangle_id"],1)
        self.assertAlmostEqual(result["payload"]["hit"]["distance"],2)

    def test_sections_keep_closed_open_coplanar_and_contacts_distinct(self):
        c=box_context()
        middle=inspect(c,self.revision,{"kind":"section","plane":{"origin":[0,0,1],"normal":[0,0,1]}})["payload"]["sections"][0]
        self.assertEqual(len(middle["curves"]),1);self.assertTrue(middle["curves"][0]["closed"])
        bottom=inspect(c,self.revision,{"kind":"section","plane":{"origin":[0,0,0],"normal":[0,0,1]}})["payload"]["sections"][0]
        self.assertEqual(len(bottom["coplanar_regions"]),2)
        self.assertEqual(len(bottom["curves"]),1);self.assertTrue(bottom["curves"][0]["closed"])
        sheet=context([[0,0,0],[2,0,0],[0,2,0]],[[0,1,2]])
        open_section=inspect(sheet,self.revision,{"kind":"section","plane":{"origin":[.5,0,0],"normal":[1,0,0]}})["payload"]["sections"][0]
        self.assertFalse(open_section["curves"][0]["closed"])
        tangent=inspect(sheet,self.revision,{"kind":"section","plane":{"origin":[0,0,0],"normal":[1,1,0]}})["payload"]["sections"][0]
        self.assertEqual(len(tangent["points"]),1);self.assertFalse(tangent["curves"])

    def test_native_cad_section_and_measure_do_not_move_or_rebuild_geometry(self):
        import cadquery as cq
        c=box_context();shape=cq.Solid.makeBox(2,2,2);revision={"id":"r1","_shape":shape}
        result=inspect(c,revision,{"kind":"section","source":"both","plane":{"origin":[0,0,1],"normal":[0,0,1]}})
        self.assertEqual(result["status"],"ok",result)
        self.assertTrue(result["payload"]["sections"][1]["curves"])
        measured=inspect(c,revision,{"kind":"measure","source":"cad"})
        self.assertAlmostEqual(measured["payload"]["cad_measurements"]["volume"],8)
        self.assertAlmostEqual(shape.Volume(),8)

    def test_unavailable_cad_stale_handles_and_limits_are_explicit(self):
        c=box_context();empty=inspect(c,self.revision,{"kind":"discrepancies"})
        self.assertEqual(empty["status"],"partial");self.assertEqual(len(empty["payload"]["source_selection"]["triangle_ids"]),12)
        bounded=inspect(c,self.revision,{"kind":"select","scope":"all","limit":2})
        self.assertFalse(bounded["payload"]["completeness"]["complete"])
        self.assertEqual(bounded["payload"]["completeness"]["unprocessed_triangle_count"],10)
        record=inspect(c,self.revision,{"kind":"select","scope":"all"})["payload"]
        record["source_hash"]="changed"
        stale=inspect(c,self.revision,{"kind":"measure","selection":{"evidence_ref":"old"}},lambda _:record)
        self.assertEqual(stale["status"],"error");self.assertEqual(stale["diagnostics"][0]["code"],"STALE_REFERENCE")

    def test_cad_selection_uses_declared_semantics_without_native_face_index_aliases(self):
        import cadquery as cq
        c=box_context();revision={"id":"r2","_shape":cq.Solid.makeBox(2,2,2),"state":{"body_ids":["body-main"],"features":{},"constructions":{}}}
        selected=inspect(c,revision,{"kind":"select","cad_entities":["body-main"]})
        self.assertEqual(selected["status"],"ok",selected)
        self.assertEqual(selected["payload"]["selection"]["cad_members"][0]["entity_ref"],"body-main")
        unknown=inspect(c,revision,{"kind":"select","cad_entities":["body:main"]})
        self.assertEqual(unknown["status"],"error")


if __name__=="__main__":unittest.main()
