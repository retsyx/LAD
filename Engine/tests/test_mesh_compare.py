"""Comparison keeps edit feedback separate from whole reconstruction approval."""
from pathlib import Path
import copy
import hashlib
import math
import sys
import unittest
import numpy as np
import cadquery as cq
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_compare import compare,check_requirements,audit_body,geometry_digest
from mesh_bounds import verify


def context_for(shape,delta=.03,explicit=True):
    vertices,triangles=shape.copy(mesh=False).tessellate(.03,.35)
    points=np.asarray([p.toTuple() for p in vertices]);indices=np.asarray(triangles,int)
    digest=hashlib.sha256(points.tobytes()+indices.tobytes()).hexdigest()
    return {'id':'context-'+digest[:16],'source_hash':digest,'units':'mm','vertices':points.tolist(),'triangles':indices.tolist(),'max_deviation':delta,'policy':{'reference_interpretation':{'material':'oriented_closed_boundary','nesting':'single_component'}} if explicit else {}}


def target(shape,context,**values):
    return {'id':'revision-1','shape':shape,'geometry_hash':geometry_digest(shape),'representation':{'status':'reconstructed_brep','method':'typed_cad_construction','source_hash':context['source_hash'],'operations':[{'operation':'compact_native_feature'}]},**values}


def cylinder_reference(count=24):
    ring=np.asarray([[math.cos(2*math.pi*i/count),math.sin(2*math.pi*i/count),0] for i in range(count)])
    faces=[]
    for i in range(count):
        a,b=ring[i],ring[(i+1)%count];c,d=a+[0,0,2],b+[0,0,2]
        faces.extend([[a,b,d],[a,d,c],[[0,0,0],b,a],[[0,0,2],c,d]])
    vertices=np.asarray(faces).reshape(-1,3)
    return {'id':'coarse-cylinder','source_hash':'coarse-cylinder-source','units':'mm','vertices':vertices.tolist(),'triangles':np.arange(len(vertices)).reshape(-1,3).tolist(),'max_deviation':.03,'policy':{'reference_interpretation':{'material':'oriented_closed_boundary','nesting':'single_component'}}}


class IterativeComparisonTests(unittest.TestCase):
    def test_preview_and_local_final_can_never_pass(self):
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape);item=target(shape,context)
        preview=compare(context,item)
        self.assertEqual(preview['acceptance'],'not_evaluated')
        self.assertIsNone(preview['geometry']['mesh_to_cad']['upper_bound'])
        self.assertTrue(any(min(s['barycentric'])>0 for s in preview['source_samples']))
        local=compare(context,item,scope={'triangle_ids':[0]},quality='final')
        self.assertEqual(local['acceptance'],'not_evaluated')
        self.assertIsNone(local['geometry']['cad_to_mesh']['sampled_max'])
        self.assertTrue(local['scope_unknown']['reverse_domain_unspecified'])
        reverse=compare(context,item,scope={"cad_face_refs":["revision-1/face/1"]},quality="final")
        self.assertEqual(reverse["acceptance"],"not_evaluated")
        self.assertFalse(reverse["source_samples"])
        self.assertTrue(reverse["geometry"]["cad_to_mesh"]["samples"])
        with self.assertRaises(ValueError):compare(context,item,scope={"cad_face_refs":["stale/face/1"]})

    def test_empty_cad_has_unavailable_distances_and_final_body_failure(self):
        context=context_for(cq.Solid.makeBox(2,3,4))
        preview=compare(context,{'shape':None,'id':'r0'})
        self.assertIsNone(preview['geometry']['mesh_to_cad']['sampled_max'])
        self.assertTrue(preview['geometry']['discrepancies'])
        self.assertTrue(all(s['distance'] is None for s in preview['source_samples']))
        self.assertEqual(compare(context,{'shape':None},quality='final')['acceptance'],'fail')

    def test_positive_box_and_step_readback_have_full_bounded_pass(self):
        import tempfile
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape)
        context['policy']['completion_obligations']=[{'id':'volume','kind':'volume','minimum':23.9,'maximum':24.1}]
        result=compare(context,target(shape,context),quality='final')
        self.assertEqual(result['acceptance'],'pass',result)
        self.assertTrue(result['scope_completed']['whole_continuous_cover'])
        self.assertLessEqual(result['geometry']['symmetric']['upper_bound'],.03)
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'part.step';cq.exporters.export(shape,str(path));reimported=cq.importers.importStep(str(path)).val()
            readback=compare(context,target(reimported,context,id='readback'),quality='final')
            self.assertEqual(readback['acceptance'],'pass',readback)

    def test_positive_cylinder_bounds_nonzero_chord_interiors(self):
        context=cylinder_reference();shape=cq.Solid.makeCylinder(1,2)
        result=compare(context,target(shape,context),quality='final')
        self.assertEqual(result['acceptance'],'pass',result)
        known=1-math.cos(math.pi/24)
        self.assertGreater(result['geometry']['mesh_to_cad']['sampled_max'],known*.5)
        for key in ['mesh_to_cad','cad_to_mesh']:
            self.assertEqual(result['geometry'][key]['guarantee'],'bounded')
            self.assertGreaterEqual(result['geometry'][key]['upper_bound'],known)
            self.assertLessEqual(result['geometry'][key]['upper_bound'],.03)

    def test_trimmed_bore_and_required_through_path_are_actual_exposed_geometry(self):
        shape=cq.Solid.makeBox(6,8,3).cut(cq.Solid.makeCylinder(1,3,cq.Vector(3,4,0)));context=context_for(shape,.15)
        obligation={'id':'bore','kind':'bore','origin':[3,4,0],'axis':[0,0,1],'radius':1,'axial_range':[0,3],'through':True,'tolerance':1e-6}
        context['policy']['completion_obligations']=[obligation]
        result=compare(context,target(shape,context),quality='final')
        self.assertEqual(result['acceptance'],'pass',result)
        self.assertTrue(all(s['distance']<.03 for s in result['source_samples']))
        wrong=cq.Solid.makeBox(6,8,3);checks=check_requirements(context,target(wrong,context),[obligation])
        self.assertEqual(checks[0]['status'],'fail')

    def test_unbuilt_small_bore_does_not_block_base_but_fails_final_completion(self):
        base=cq.Solid.makeBox(6,8,3);drilled=base.cut(cq.Solid.makeCylinder(.05,3,cq.Vector(3,4,0)));context=context_for(drilled,.5)
        context['policy']['completion_obligations']=[{'id':'tiny-bore','kind':'bore','origin':[3,4,0],'axis':[0,0,1],'radius':.05,'through':True}]
        self.assertEqual(audit_body(base)['status'],'pass')
        preview=compare(context,target(base,context))
        self.assertEqual(preview['acceptance'],'not_evaluated')
        self.assertEqual(preview['feature_checks']['completion_obligations'][0]['status'],'fail')
        final=compare(context,target(base,context),quality='final')
        self.assertEqual(final['acceptance'],'fail')

    def test_authored_triangle_loop_and_circular_facet_replay_are_not_approved(self):
        box=cq.Solid.makeBox(2,3,4);context=context_for(box)
        script='import cadquery as cq\nfaces=[]\nfor triangle in triangles:\n    faces.append(cq.Face.makeFromWires(cq.Wire.makePolygon(triangle,close=True)))\n'
        item=target(box,context,script=script);item['representation']['method']='authored_program'
        self.assertNotEqual(compare(context,item,quality='final')['acceptance'],'pass')
        context=cylinder_reference();ring=[[math.cos(2*math.pi*i/24),math.sin(2*math.pi*i/24)] for i in range(24)]
        faceted=cq.Workplane('XY').polyline(ring).close().extrude(2).val()
        result=compare(context,target(faceted,context),quality='final')
        self.assertNotEqual(result['acceptance'],'pass')
        self.assertEqual(next(c for c in result['representation_checks'] if c['kind']=='circular_tessellation_replay')['status'],'inconclusive')

    def test_genuine_small_polyhedral_profile_can_pass(self):
        shape=cq.Workplane('XY').polyline([[0,0],[3,0],[1,2]]).close().extrude(2).val();context=context_for(shape)
        self.assertEqual(compare(context,target(shape,context),quality='final')['acceptance'],'pass')

    def test_missing_interpretation_conversion_margin_and_budget_are_inconclusive(self):
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape,explicit=False)
        self.assertEqual(compare(context,target(shape,context),quality='final')['acceptance'],'inconclusive')
        context=context_for(shape);context['policy']['compare_policy']={'final_max_cells':1}
        self.assertEqual(compare(context,target(shape,context),quality='final')['acceptance'],'inconclusive')
        context=context_for(shape,.001);context['conversion_arithmetic_margin']=.002
        self.assertEqual(compare(context,target(shape,context),quality='final')['acceptance'],'inconclusive')
        context['policy']['compare_policy']={'ignored_budget':1}
        with self.assertRaises(ValueError):compare(context,target(shape,context))

    def test_source_topology_is_audited_before_working_unit_rounding(self):
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape)
        context["original_vertices"]=(np.asarray(context["vertices"])/10).tolist()
        context["source_units"]="cm";context["source_transform"]={"scale":10}
        context["source_hash"]="original-cm-"+context["source_hash"]
        context["conversion_arithmetic_margin"]=1e-12
        result=compare(context,target(shape,context),quality="final")
        self.assertEqual(result["acceptance"],"pass",result)
        audit=result["reference_assumptions"]["source_audit"]
        self.assertIn("original represented",audit["predicates_frame"])
        self.assertTrue(audit["working_incidence_preserved"])

    def test_invalid_intermediate_and_unknown_semantic_reference_are_explicit(self):
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape);face=shape.Faces()[0]
        report=compare(context,target(face,context))
        self.assertEqual(report['acceptance'],'not_evaluated')
        self.assertEqual(audit_body(face)['status'],'fail')
        self.assertEqual(compare(context,target(face,context),quality='final')['acceptance'],'fail')
        self.assertEqual(check_requirements(context,target(shape,context),['unknown-feature'])[0]['status'],'inconclusive')
        self.assertEqual(check_requirements(context,target(shape,context),[{"kind":"volume","minimum":float("nan")}])[0]["status"],"inconclusive")
        cylinder=cq.Solid.makeCylinder(1,2)
        invalid_axis={"kind":"cylinder","origin":[0,0,0],"axis":[1e308,0,0],"radius":1}
        self.assertEqual(check_requirements(context,target(cylinder,context),[invalid_axis])[0]["status"],"fail")

    def test_source_samples_are_paired_and_comparison_does_not_mesh_the_original(self):
        from OCP.BRep import BRep_Tool
        from OCP.TopLoc import TopLoc_Location
        shape=cq.Solid.makeBox(2,3,4);context=context_for(shape);original=shape.copy(mesh=False)
        before=[BRep_Tool.Triangulation_s(f.wrapped,TopLoc_Location()) is None for f in original.Faces()]
        a=compare(context,target(cq.Solid.makeBox(2,3,2),context,id='before'))
        b=compare(context,target(original,context,id='after'))
        self.assertEqual([s['id'] for s in a['source_samples']],[s['id'] for s in b['source_samples']])
        self.assertGreater(a['geometry']['mesh_to_cad']['area_weighted_rms'],b['geometry']['mesh_to_cad']['area_weighted_rms'])
        self.assertEqual(before,[BRep_Tool.Triangulation_s(f.wrapped,TopLoc_Location()) is None for f in original.Faces()])

    def test_interior_rational_bulge_is_not_certified_from_matching_corners(self):
        from OCP.Geom import Geom_BezierSurface
        from OCP.TColgp import TColgp_Array2OfPnt
        from OCP.gp import gp_Pnt
        from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
        poles=TColgp_Array2OfPnt(1,3,1,3)
        for i in range(1,4):
            for j in range(1,4):poles.SetValue(i,j,gp_Pnt(i-1,j-1,1 if i==j==2 else 0))
        face=cq.Face(BRepBuilderAPI_MakeFace(Geom_BezierSurface(poles),1e-9).Face())
        mesh=np.asarray([[[0,0,0],[2,0,0],[2,2,0]],[[0,0,0],[2,2,0],[0,2,0]]],float)
        self.assertFalse(verify(mesh,face,.01,max_cells=300)['accepted'])


if __name__=='__main__':unittest.main()
