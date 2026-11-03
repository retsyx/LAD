"""Local geometric alternatives fitted to immutable inspection evidence.

Fits are construction geometry, not solid edits. Observed support, inferred
continuations and sampled diagnostics are kept separate throughout.
"""
from __future__ import annotations

import copy
import itertools
import json
import math

import numpy as np
from scipy.optimize import least_squares

from mesh_inspect import EvidenceError,_analysis,_selection,_hash,_frame,diagnostic

VERSION="iterative-fit-1"
SUPPORTED={"plane","line","circle","cylinder","cone","sphere","profile","extrusion","revolution"}
RECOGNIZED={"torus","helical_sweep","rounded_rectangle_extrusion","concentric_spherical_shell"}


def _unit(vector):
    vector=np.asarray(vector,float);length=float(np.linalg.norm(vector))
    if not math.isfinite(length) or length<1e-14:raise EvidenceError("NUMERICAL_FAILURE","A fitted direction is degenerate")
    return vector/length


def _canonical(vector):
    vector=_unit(vector)
    return -vector if vector[int(np.argmax(np.abs(vector)))]<0 else vector


def _circle(points,weights=None):
    center=np.average(points,axis=0,weights=weights);q=points-center
    matrix=np.column_stack((2*q,np.ones(len(q))));target=np.sum(q*q,axis=1)
    if np.linalg.matrix_rank(matrix)<3:return None
    if weights is not None:
        root=np.sqrt(weights);matrix=matrix*root[:,None];target=target*root
    answer=np.linalg.lstsq(matrix,target,rcond=None)[0]
    radius2=float(answer[-1]+answer[:-1]@answer[:-1])
    if radius2<=0:return None
    return center+answer[:-1],math.sqrt(radius2)


def _samples(context,evidence,maximum):
    analysis=_analysis(context);selection=_selection(evidence,context,None)
    points=[];weights=[];provenance=[];diagnostics=[];normals=[];verification=[];verification_ids=[]
    for tid,parts in selection.items():
        for polygon in parts:
            bary=np.asarray(polygon,float);vertices=bary@analysis["faces"][tid]
            for i in range(1,len(vertices)-1):
                b=bary[[0,i,i+1]];face=vertices[[0,i,i+1]];area=float(np.linalg.norm(np.cross(face[1]-face[0],face[2]-face[0]))/2)
                verification.extend(face);verification_ids.extend([tid]*3)
                if context.get("source_kind") in ("scan",):
                    points.append(face.mean(axis=0));weights.append(max(area,1e-20));provenance.append({"triangle_id":tid,"barycentric":b.mean(axis=0).tolist(),"category":"triangle_interior"});normals.append(analysis["normals"][tid])
                else:
                    for p,barypoint in zip(face,b):
                        points.append(p);weights.append(max(area/3,1e-20));provenance.append({"triangle_id":tid,"barycentric":barypoint.tolist(),"category":"original_or_clipped_vertex"});normals.append(analysis["normals"][tid])
                diagnostics.append((face.mean(axis=0),tid,area))
    # Section samples remain in the exact observed plane and retain source
    # segment correspondence; no invented closure is admitted as observation.
    if not points:
        for section in evidence.get("sections",[]):
            if section.get("source") not in ("reference","source"):continue
            for curve in section.get("curves",[]):
                vertices=np.asarray(curve.get("points",[]),float)
                if len(vertices)<2:continue
                for i,p in enumerate(vertices):
                    length=float(np.linalg.norm(vertices[min(i+1,len(vertices)-1)]-vertices[max(0,i-1)]))/2
                    points.append(p);weights.append(max(length,1e-20));normals.append(np.zeros(3))
                    provenance.append({"section_plane":section["plane"],"section_curve":curve.get("id"),"index":i,"category":"section_vertex"})
    if not points:raise EvidenceError("INSUFFICIENT_EVIDENCE","Evidence contains no source points or usable source sections")
    points=np.asarray(points,float);weights=np.asarray(weights,float);normals=np.asarray(normals,float)
    full_points=np.asarray(verification,float) if verification else points.copy()
    # Area-aware deterministic sampling; all source IDs remain in the evidence
    # and the independent diagnostic pass, including downweighted observations.
    if len(points)>maximum:
        cumulative=np.cumsum(weights);indices=np.searchsorted(cumulative,(np.arange(maximum)+.5)*cumulative[-1]/maximum)
        indices=np.unique(np.r_[indices,np.linspace(0,len(points)-1,min(64,maximum//4),dtype=int)])
        points=points[indices];weights=weights[indices];normals=normals[indices];provenance=[provenance[i] for i in indices]
    weights/=max(float(weights.sum()),1e-300)
    return {"points":points,"weights":weights,"normals":normals,"provenance":provenance,"diagnostic":diagnostics,"triangle_ids":sorted(selection),
            "verification_points":full_points,"verification_triangle_ids":verification_ids}


def _residual(geometry,points):
    family=geometry["kind"]
    if family=="plane":return (points-geometry["origin"])@_unit(geometry["normal"])
    if family=="line":
        q=points-geometry["origin"];a=_unit(geometry["direction"]);return np.linalg.norm(q-(q@a)[:,None]*a,axis=1)
    if family=="sphere":return np.linalg.norm(points-geometry["center"],axis=1)-geometry["radius"]
    if family=="circle":
        q=points-geometry["center"];a=_unit(geometry["normal"]);z=q@a;rho=np.linalg.norm(q-z[:,None]*a,axis=1)
        return np.hypot(rho-geometry["radius"],z)
    if family in ("cylinder","cone"):
        q=points-geometry["origin"];a=_unit(geometry["axis"]);z=q@a;rho=np.linalg.norm(q-z[:,None]*a,axis=1)
        if family=="cylinder":return rho-geometry["radius"]
        expected=geometry["radius"]+geometry["slope"]*z
        radial=(rho-expected)/math.sqrt(1+geometry["slope"]**2)
        if abs(geometry["slope"])>1e-12:
            apex=-geometry["radius"]/geometry["slope"]
            radial=np.where(expected<0,np.hypot(rho,z-apex),radial)
        return radial
    return None


def _primitive_starts(family,data,origin,scale):
    points=(data["points"]-origin)/scale;weights=data["weights"];center=np.average(points,axis=0,weights=weights)
    q=points-center;values,vectors=np.linalg.eigh((q*weights[:,None]).T@q)
    if family=="plane":
        if values[1]<max(values[-1],1e-30)*1e-10:return []
        normal=_canonical(vectors[:,0]);return [{"kind":"plane","origin":(origin+center*scale).tolist(),"normal":normal.tolist(),"x_direction":_canonical(vectors[:,-1]).tolist()}]
    if family=="line":
        if values[-1]<=1e-20:return []
        return [{"kind":"line","origin":(origin+center*scale).tolist(),"direction":_canonical(vectors[:,-1]).tolist()}]
    if family=="circle":
        normal=_canonical(vectors[:,0]);x,y,_=_frame(normal);projection=np.column_stack((q@x,q@y));fit=_circle(projection,weights)
        if fit is None:return []
        c,r=fit
        return [{"kind":"circle","center":(origin+(center+x*c[0]+y*c[1])*scale).tolist(),"normal":normal.tolist(),"x_direction":x.tolist(),"radius":r*scale}]
    if family=="sphere":
        matrix=np.column_stack((2*q,np.ones(len(q))));target=np.sum(q*q,axis=1)
        if np.linalg.matrix_rank(matrix)<4:return []
        answer=np.linalg.lstsq(matrix*np.sqrt(weights)[:,None],target*np.sqrt(weights),rcond=None)[0]
        radius2=float(answer[-1]+answer[:3]@answer[:3])
        if radius2<=0 or radius2>1e8:return []
        return [{"kind":"sphere","center":(origin+(center+answer[:3])*scale).tolist(),"radius":math.sqrt(radius2)*scale}]
    normals=data["normals"];normal_cov=(normals*weights[:,None]).T@normals
    _,normal_axes=np.linalg.eigh(normal_cov);axes=[normal_axes[:,0],*vectors.T,*np.eye(3)]
    result=[]
    for raw in axes:
        axis=_canonical(raw)
        if any(abs(float(axis@np.asarray(item["axis"])))>1-1e-8 for item in result):continue
        x,y,axis=_frame(axis);projection=np.column_stack((q@x,q@y));circle=_circle(projection,weights)
        if circle is None:continue
        c,r=circle;point=center+x*c[0]+y*c[1]
        geometry={"kind":family,"origin":(origin+point*scale).tolist(),"axis":axis.tolist(),"radius":r*scale}
        if family=="cone":
            z=(points-point)@axis;rho=np.linalg.norm((points-point)-z[:,None]*axis,axis=1)
            slope,intercept=np.linalg.lstsq(np.column_stack((z,np.ones(len(z))))*np.sqrt(weights)[:,None],rho*np.sqrt(weights),rcond=None)[0]
            if intercept<=0:continue
            geometry.update(radius=float(intercept*scale),slope=float(slope),half_angle=abs(math.atan(float(slope))))
        result.append(geometry)
    return result[:6]


def _optimize_primitive(geometry,data,length_scale):
    kind=geometry["kind"];original=copy.deepcopy(geometry);points=data["points"];weights=np.sqrt(data["weights"])
    if kind in ("plane","line"):return geometry,{"iterations":0,"converged":True,"condition_ratio":1.}
    if kind in ("sphere","circle"):
        center=np.asarray(geometry["center"]);start=np.r_[np.zeros(3),geometry["radius"]/length_scale]
        def unpack(v):
            item=copy.deepcopy(original);item["center"]=(center+v[:3]*length_scale).tolist();item["radius"]=float(v[3]*length_scale);return item
        low=[-np.inf]*3+[1e-10];high=[np.inf]*4
    else:
        axis=_unit(geometry["axis"]);x,y,_=_frame(axis);center=np.asarray(geometry["origin"])
        start=[0,0,0,0,geometry["radius"]/length_scale]+([geometry["slope"]] if kind=="cone" else [])
        def unpack(v):
            item=copy.deepcopy(original);a=_unit(axis+v[0]*x+v[1]*y);c=center+length_scale*(v[2]*x+v[3]*y)
            item.update(axis=a.tolist(),origin=c.tolist(),radius=float(v[4]*length_scale))
            if kind=="cone":item.update(slope=float(v[5]),half_angle=abs(math.atan(float(v[5]))))
            return item
        low=[-2,-2,-np.inf,-np.inf,1e-10]+([-10] if kind=="cone" else []);high=[2,2,np.inf,np.inf,np.inf]+([10] if kind=="cone" else [])
    answer=least_squares(lambda v:_residual(unpack(v),points)*weights/length_scale,start,bounds=(low,high),max_nfev=100,x_scale="jac",loss="soft_l1",f_scale=1e-4)
    singular=np.linalg.svd(answer.jac,compute_uv=False)
    ratio=float(singular[-1]/singular[0]) if len(singular) and singular[0]>0 else 0.
    return unpack(answer.x),{"iterations":int(answer.nfev),"converged":bool(answer.success),"condition_ratio":ratio,"message":str(answer.message)}


def _extent(geometry,data):
    points=data["points"];kind=geometry["kind"]
    result={"bounds":{"min":points.min(axis=0).tolist(),"max":points.max(axis=0).tolist()},"triangle_ids":data["triangle_ids"],"classification":"observed_support_only"}
    if kind in ("cylinder","cone"):
        axis=_unit(geometry["axis"]);x,y,_=_frame(axis);q=points-geometry["origin"];z=q@axis;theta=np.arctan2(q@y,q@x)
        values=np.sort(np.unique(theta));gaps=np.diff(np.r_[values,values[0]+2*math.pi]);cut=int(np.argmax(gaps));start=values[(cut+1)%len(values)];span=2*math.pi-float(gaps[cut])
        result.update(axial_interval=[float(z.min()),float(z.max())],angular_interval=[float(start),float(start+span)],angular_span=span,
                      terminal_faces_observed=False,unsupported_angular_gap=float(gaps[cut]),seam_convention="largest unsupported gap; no convex filling of footprint")
    elif kind=="line":
        t=(points-geometry["origin"])@_unit(geometry["direction"]);result["parameter_interval"]=[float(t.min()),float(t.max())]
    elif kind=="sphere":
        directions=(points-geometry["center"])/geometry["radius"];result["direction_span_singular_values"]=np.linalg.svd(directions-directions.mean(axis=0),compute_uv=False).tolist()
    return result


def _stats(geometry,data):
    residual=np.abs(_residual(geometry,data["points"]));weights=data["weights"]
    original=np.abs(_residual(geometry,data["verification_points"]))
    diagnostics=data["diagnostic"];middle=np.asarray([p for p,_,_ in diagnostics]) if diagnostics else np.empty((0,3))
    check=np.abs(_residual(geometry,middle)) if len(middle) else np.empty(0)
    return {"source_vertex_or_fit_sample_maximum":float(original.max()),"optimization_sample_maximum":float(residual.max()),"area_weighted_rms":float(np.sqrt(np.sum(weights*residual**2))),
            "triangle_interior_sampled_maximum":float(check.max()) if len(check) else None,"sample_count":len(residual),"diagnostic_sample_count":len(check),
            "guarantee":"sampled","method":"area-aware original/clipped vertices or scan interiors; independent original triangle centroids",
            "residual_samples":[{**p,"distance":float(r)} for p,r in zip(data["provenance"],residual)]}


def _profile_from_sections(evidence,tolerance):
    sections=[s for s in evidence.get("sections",[]) if s.get("source") in ("reference","source")]
    if not sections:return None
    section=next((s for s in sections if s.get("curves")),None)
    if section is None or section.get("branches"):return None
    origin=np.asarray(section["plane"]["origin"]);normal=_unit(section["plane"]["normal"]);x=_unit(section["frame"]["x_direction"]);y=np.cross(normal,x)
    loops=[];maximum=0.
    for curve in section["curves"]:
        p=np.asarray(curve["points"],float);q=np.column_stack(((p-origin)@x,(p-origin)@y));closed=bool(curve.get("closed"))
        if closed and np.linalg.norm(q[0]-q[-1])<1e-10:q=q[:-1]
        if len(q)<2:return None
        segments,error=_fit_polycurve(q,closed,tolerance)
        if not segments:return None
        maximum=max(maximum,error);loops.append({"closed":closed,"segments":segments,"observed":True,"inferred_closing_segment":False})
    if not loops:return None
    # Nesting is an observed planar relationship; loops remain individually
    # addressable and are not silently filled into an arbitrary sketch.
    for i,loop in enumerate(loops):loop["role"]="outer" if i==0 else "unclassified_nested_or_disconnected"
    return {"kind":"profile","origin":origin.tolist(),"normal":normal.tolist(),"x_direction":x.tolist(),"loops":loops},maximum


def _fit_polycurve(points,closed,tolerance):
    points=np.asarray(points,float)
    if closed:
        circle=_circle(points)
        if circle:
            center,radius=circle;error=float(np.max(np.abs(np.linalg.norm(points-center,axis=1)-radius)))
            if error<=tolerance and len(points)>=5:
                positions=[center+radius*np.array([math.cos(i*math.pi/4),math.sin(i*math.pi/4)]) for i in range(8)]
                return [{"kind":"arc","start":positions[2*i].tolist(),"mid":positions[(2*i+1)%8].tolist(),"end":positions[(2*i+2)%8].tolist()} for i in range(4)],error
        points=np.vstack((points,points[0]))
    # Search breakpoints are bounded; every proposed span is checked against
    # every original section point between its endpoints.
    candidates=np.unique(np.r_[0,len(points)-1,np.linspace(0,len(points)-1,min(len(points),128),dtype=int)])
    best={0:(0.,[],0.)}
    for j in range(1,len(candidates)):
        end=int(candidates[j]);winner=None
        for i in range(j):
            if i not in best:continue
            start=int(candidates[i]);span=points[start:end+1];direction=span[-1]-span[0];length=float(direction@direction)
            if length>0:
                t=np.clip((span-span[0])@direction/length,0,1);error=float(np.max(np.linalg.norm(span-span[0]-t[:,None]*direction,axis=1)))
                if error<=tolerance:
                    segment={"kind":"line","start":span[0].tolist(),"end":span[-1].tolist()};score=best[i][0]+2+error/max(tolerance,1e-30)*.1
                    if winner is None or score<winner[0]:winner=(score,best[i][1]+[segment],max(best[i][2],error))
            if len(span)>=5:
                fit=_circle(span)
                if fit:
                    center,radius=fit;angles=np.unwrap(np.arctan2(span[:,1]-center[1],span[:,0]-center[0]));travel=np.diff(angles)
                    error=float(np.max(np.abs(np.linalg.norm(span-center,axis=1)-radius)))
                    if error<=tolerance and .1<abs(angles[-1]-angles[0])<2*math.pi and (np.all(travel>=-1e-8) or np.all(travel<=1e-8)):
                        mid=center+radius*np.array([math.cos((angles[0]+angles[-1])/2),math.sin((angles[0]+angles[-1])/2)])
                        segment={"kind":"arc","start":span[0].tolist(),"mid":mid.tolist(),"end":span[-1].tolist()};score=best[i][0]+3+error/max(tolerance,1e-30)*.1
                        if winner is None or score<winner[0]:winner=(score,best[i][1]+[segment],max(best[i][2],error))
        if winner and len(winner[1])<=24:best[j]=winner
    result=best.get(len(candidates)-1)
    if not result:return None,None
    # Long chains of tiny straight chords are not a smooth profile fallback.
    if len(result[1])>12 and all(segment["kind"]=="line" for segment in result[1]):return None,None
    return result[1],result[2]


def _polycurve_distance(points,segments):
    result=np.full(len(points),np.inf)
    for segment in segments:
        a,b=np.asarray(segment["start"]),np.asarray(segment["end"])
        if segment["kind"]=="line":
            edge=b-a;length=float(edge@edge)
            if length<=0:continue
            t=np.clip((points-a)@edge/length,0,1);distance=np.linalg.norm(points-a-t[:,None]*edge,axis=1)
        else:
            mid=np.asarray(segment["mid"]);fit=_circle(np.asarray([a,mid,b]))
            if fit is None:continue
            center,radius=fit;angles=np.unwrap(np.arctan2(np.asarray([a,mid,b])[:,1]-center[1],np.asarray([a,mid,b])[:,0]-center[0]))
            theta=np.arctan2(points[:,1]-center[1],points[:,0]-center[0]);theta+=np.round(((angles[0]+angles[-1])/2-theta)/(2*math.pi))*2*math.pi
            inside=(theta>=min(angles[0],angles[-1]))&(theta<=max(angles[0],angles[-1]))
            distance=np.where(inside,np.abs(np.linalg.norm(points-center,axis=1)-radius),np.minimum(np.linalg.norm(points-a,axis=1),np.linalg.norm(points-b,axis=1)))
        result=np.minimum(result,distance)
    return result


def _revolution(context,evidence,data,tolerance):
    from mesh_inspect import _source_sections,_clip
    analysis=_analysis(context);selection=_selection(evidence,context,None);points=data["points"]
    center=np.average(points,axis=0,weights=data["weights"]);q=points-center
    _,axes=np.linalg.eigh((q*data["weights"][:,None]).T@q)
    _,normal_axes=np.linalg.eigh((data["normals"]*data["weights"][:,None]).T@data["normals"])
    candidates=[normal_axes[:,0],*axes.T];best=None
    for candidate_axis in candidates[:4]:
        axis=_canonical(candidate_axis);x,y,_=_frame(axis);profiles=[];failed=False
        for azimuth in (.117,.117+math.pi/3,.117+2*math.pi/3):
            radial=x*math.cos(azimuth)+y*math.sin(azimuth);normal=np.cross(radial,axis)
            section=_source_sections(analysis,selection,{"origin":center.tolist(),"normal":normal.tolist()})
            if section["branches"] or section["coplanar_regions"]:failed=True;break
            loops=[]
            for curve in section["curves"]:
                world=np.asarray(curve["points"]);uv=np.column_stack(((world-center)@radial,(world-center)@axis))
                if curve["closed"]:
                    polygon=uv[:-1].tolist() if np.linalg.norm(uv[0]-uv[-1])<1e-9 else uv.tolist()
                    positive=_clip(polygon,lambda p:p[0])
                    if positive:loops.append((np.asarray(positive),True,bool(np.any(uv[:,0]<0))))
                elif np.all(uv[:,0]>=-tolerance):loops.append((uv,False,False))
            if not loops:failed=True;break
            profiles.append((radial,loops))
        if failed or len(profiles)!=3 or len({len(item[1]) for item in profiles})!=1:continue
        loops=[];error=0.
        for coords,closed,inferred in profiles[0][1]:
            segments,fit_error=_fit_polycurve(coords,closed,tolerance)
            if not segments:failed=True;break
            loops.append({"closed":closed,"segments":segments,"observed":True,"role":"unclassified","inferred_axis_closure":inferred})
            error=max(error,fit_error)
        if failed:continue
        segments=[segment for loop in loops for segment in loop["segments"]]
        for _,observed in profiles[1:]:
            for coords,_closed,_inferred in observed:error=max(error,float(_polycurve_distance(coords,segments).max()))
        radial_vector=q-(q@axis)[:,None]*axis;rho=np.linalg.norm(radial_vector,axis=1);axial=q@axis
        error=max(error,float(_polycurve_distance(np.column_stack((rho,axial)),segments).max()))
        if error>tolerance:continue
        # Actual triangle angular coverage, rather than vertex span, determines
        # observed azimuth intervals. The gap remains explicit in the geometry.
        intervals=[]
        for tid in selection:
            face=analysis["faces"][tid]-center;radial=np.linalg.norm(face-(face@axis)[:,None]*axis,axis=1)
            angles=np.mod(np.arctan2(face@y,face@x),2*math.pi)[radial>analysis["scale"]*1e-10]
            if len(angles)<2:continue
            angles=np.sort(angles);gaps=np.diff(np.r_[angles,angles[0]+2*math.pi]);cut=int(np.argmax(gaps));start=float(angles[(cut+1)%len(angles)]);span=2*math.pi-float(gaps[cut])
            if start+span<=2*math.pi:intervals.append([start,start+span])
            else:intervals.extend([[start,2*math.pi],[0,start+span-2*math.pi]])
        merged=[]
        for start,end in sorted(intervals):
            if merged and start<=merged[-1][1]+1e-12:merged[-1][1]=max(merged[-1][1],end)
            else:merged.append([start,end])
        radial=profiles[0][0];normal=np.cross(radial,axis)
        geometry={"kind":"revolution","origin":center.tolist(),"axis":axis.tolist(),"x_direction":radial.tolist(),
                  "profile":{"kind":"profile","origin":center.tolist(),"normal":normal.tolist(),"x_direction":radial.tolist(),"loops":loops},
                  "observed_angle_intervals":merged}
        if best is None or error<best[1]:best=geometry,error
    return best


def _generated_candidate(family,evidence,tolerance,context=None,data=None):
    if family=="revolution":return _revolution(context,evidence,data,tolerance)
    profile=_profile_from_sections(evidence,tolerance)
    if profile is None:return None
    geometry,error=profile
    if family=="profile":return geometry,error
    sections=[s for s in evidence.get("sections",[]) if s.get("source") in ("reference","source") and s.get("curves")]
    if family=="extrusion":
        if len(sections)<2 or any(not loop["closed"] for loop in geometry["loops"]):return None
        normal=_unit(geometry["normal"]);origin=np.asarray(geometry["origin"]);x=_unit(geometry["x_direction"]);y=np.cross(normal,x)
        first=np.concatenate([np.asarray(curve["points"]) for curve in sections[0]["curves"]]);reference=np.column_stack(((first-origin)@x,(first-origin)@y));interval=[]
        from scipy.spatial import cKDTree
        for section in sections:
            if abs(float(_unit(section["plane"]["normal"])@normal))<1-1e-7 or len(section["curves"])!=len(sections[0]["curves"]):return None
            points=np.concatenate([np.asarray(curve["points"]) for curve in section["curves"]]);q=np.column_stack(((points-origin)@x,(points-origin)@y))
            # This is a conservative planning screen of sampled traces; detailed
            # profile-to-segment checks are reported separately, never certified.
            mismatch=max(float(cKDTree(reference).query(q)[0].max()),float(cKDTree(q).query(reference)[0].max()))
            if mismatch>max(tolerance*4,np.linalg.norm(np.ptp(reference,axis=0))*.02):return None
            error=max(error,mismatch);interval.append(float((np.asarray(section["plane"]["origin"])-origin)@normal))
        if max(interval)-min(interval)<=tolerance:return None
        return {"kind":"extrusion","profile":geometry,"direction":normal.tolist(),"observed_interval":[min(interval),max(interval)]},error
    return None


def _binding(constraint,members,evidence_ids):
    ref=constraint.get("member",constraint.get("target",constraint.get("evidence_ref")))
    if ref is None and len(members)==1:return members[0]["id"]
    matches=[member["id"] for member in members if ref in (member["id"],member.get("role"),member.get("evidence_id"))]
    if len(matches)!=1:raise EvidenceError("CONSTRAINT_CONFLICT","Constraint target must identify exactly one fitted member")
    return matches[0]


def _compile_constraints(constraints,members,resolve_reference):
    result=[];byid={m["id"]:m for m in members}
    for raw in constraints:
        if not isinstance(raw,dict) or raw.get("strength","hard") not in ("hard","soft"):raise EvidenceError("INVALID_CONSTRAINT","Constraint records require hard or soft strength")
        item=copy.deepcopy(raw);kind=item.get("kind")
        if kind=="fixed":
            identity=_binding(item,members,[]);parameter=item.get("parameter");geometry=byid[identity]["geometry"]
            if parameter not in geometry or parameter=="kind":raise EvidenceError("INVALID_CONSTRAINT","Fixed parameter is not available on the selected family")
            value=item.get("value");array=np.asarray(value,float)
            if not np.isfinite(array).all() or array.shape!=np.asarray(geometry[parameter]).shape:raise EvidenceError("INVALID_CONSTRAINT","Fixed value has invalid dimensions or nonfinite coordinates")
            item.update(member=identity)
            if parameter in {"axis","normal","direction","x_direction"}:item["value"]=_unit(value).tolist()
            if parameter=="radius" and float(value)<=0:raise EvidenceError("CONSTRAINT_CONFLICT","A radius must remain positive")
            if parameter=="half_angle" and geometry["kind"]=="cone":
                if not 0<=float(value)<math.pi/2:raise EvidenceError("CONSTRAINT_CONFLICT","A cone half-angle must be in [0, pi/2)")
                item.update(parameter="slope",value=math.tan(float(value))*(-1 if geometry["slope"]<0 else 1),derived_parameter="half_angle")
        elif kind in ("coaxial","parallel","perpendicular","equal_radius","concentric"):
            refs=item.get("members",item.get("evidence_refs",item.get("entities")))
            if not isinstance(refs,list) or len(refs)!=2:raise EvidenceError("INVALID_CONSTRAINT","A shared relationship requires two explicit member/evidence references")
            item["members"]=[_binding({"target":ref},members,[]) for ref in refs]
            if len(set(item["members"]))!=2:raise EvidenceError("INVALID_CONSTRAINT","A relationship needs distinct members")
            a,b=[byid[identity]["geometry"] for identity in item["members"]]
            if kind=="coaxial" and not all("axis" in g and "origin" in g for g in (a,b)):raise EvidenceError("INCOMPATIBLE_FAMILY","Coaxiality requires two axis-bearing surface members")
        else:raise EvidenceError("UNSUPPORTED_CONSTRAINT",f"Constraint {kind} has no constraint-preserving implementation")
        result.append(item)
    fixed={}
    for item in result:
        if item["kind"]=="fixed" and item.get("strength","hard")=="hard":
            key=(item["member"],item["parameter"])
            if key in fixed and fixed[key]!=item["value"]:raise EvidenceError("CONSTRAINT_CONFLICT","One parameter has contradictory fixed values")
            fixed[key]=item["value"]
    return result


def _constrain(members,constraints):
    members=copy.deepcopy(members);items={member["id"]:member["geometry"] for member in members}
    fixed={(c["member"],c["parameter"]) for c in constraints if c["kind"]=="fixed" and c.get("strength","hard")=="hard"}
    for c in constraints:
        if c["kind"]=="fixed" and c.get("strength","hard")=="hard":items[c["member"]][c["parameter"]]=copy.deepcopy(c["value"])
    for _ in range(max(1,len(constraints))):
        for c in constraints:
            if c.get("strength","hard")!="hard" or c["kind"]=="fixed":continue
            a_id,b_id=c["members"];a,b=items[a_id],items[b_id];kind=c["kind"]
            if kind=="equal_radius":key="radius"
            elif kind=="concentric":key="center"
            else:key="axis" if "axis" in a and "axis" in b else "normal" if "normal" in a and "normal" in b else None
            if key is None or key not in a or key not in b:raise EvidenceError("UNSUPPORTED_CONSTRAINT",f"{kind} is not available on the selected member families")
            if (b_id,key) in fixed and (a_id,key) not in fixed:a,b=b,a;a_id,b_id=b_id,a_id
            if kind in ("equal_radius","concentric","parallel","coaxial"):b[key]=copy.deepcopy(a[key])
            elif kind=="perpendicular":
                aa=_unit(a[key]);bb=np.asarray(b[key])-aa*float(np.asarray(b[key])@aa)
                if np.linalg.norm(bb)<1e-12:bb=_frame(aa)[0]
                b[key]=_unit(bb).tolist()
            if kind=="coaxial":
                if "origin" not in a or "origin" not in b:raise EvidenceError("UNSUPPORTED_CONSTRAINT","Coaxial members require axis origins")
                axis=_unit(a[key]);delta=np.asarray(b["origin"])-a["origin"]
                b["origin"]=(np.asarray(a["origin"])+axis*float(delta@axis)).tolist()
    for c in constraints:
        if c["kind"]=="fixed" and c.get("strength","hard")=="hard":items[c["member"]][c["parameter"]]=copy.deepcopy(c["value"])
    for geometry in items.values():
        if geometry.get("kind")=="cone":geometry["half_angle"]=abs(math.atan(geometry["slope"]))
        if "radius" in geometry and (not math.isfinite(geometry["radius"]) or geometry["radius"]<=0):raise EvidenceError("CONSTRAINT_CONFLICT","Fitted geometry requires a positive finite radius")
        if "normal" in geometry and "x_direction" in geometry:
            normal=_unit(geometry["normal"]);x=np.asarray(geometry["x_direction"])-normal*float(np.asarray(geometry["x_direction"])@normal)
            if np.linalg.norm(x)<1e-12:x=_frame(normal)[0]
            geometry["x_direction"]=_unit(x).tolist()
    return members


def _constraint_reports(members,constraints,scale):
    items={m["id"]:m["geometry"] for m in members};hard=[];soft=[]
    for c in constraints:
        kind=c["kind"]
        if kind=="fixed":
            residual=float(np.linalg.norm(np.asarray(items[c["member"]][c["parameter"]])-c["value"]));tolerance=1e-8 if c["parameter"] in {"axis","normal","direction","x_direction","half_angle","slope"} else scale*1e-9
        else:
            a,b=[items[identity] for identity in c["members"]]
            if kind=="equal_radius":residual=abs(a["radius"]-b["radius"]);tolerance=scale*1e-9
            elif kind=="concentric":residual=float(np.linalg.norm(np.asarray(a["center"])-b["center"]));tolerance=scale*1e-9
            else:
                key="axis" if "axis" in a else "normal";aa,bb=_unit(a[key]),_unit(b[key]);residual=float(abs(aa@bb) if kind=="perpendicular" else np.linalg.norm(np.cross(aa,bb)));tolerance=1e-8
                if kind=="coaxial":residual=max(residual,float(np.linalg.norm(np.cross(np.asarray(a["origin"])-b["origin"],aa)))/scale)
        record={"constraint":c,"residual":residual,"construction_tolerance":tolerance,"satisfied":residual<=tolerance}
        (hard if c.get("strength","hard")=="hard" else soft).append(record)
    return hard,soft


def _joint_refine(members,data_byid,constraints,scale):
    if not constraints:return members
    fixed={(c["member"],c["parameter"]) for c in constraints if c["kind"]=="fixed" and c.get("strength","hard")=="hard"}
    variables=[];start=[];lower=[];upper=[]
    for member in members:
        identity=member["id"];geometry=member["geometry"]
        for key in ("origin","center","radius","slope","axis","normal","direction"):
            if key not in geometry or (identity,key) in fixed:continue
            values=geometry[key] if isinstance(geometry[key],list) else [geometry[key]]
            for i,value in enumerate(values):
                directional=key in {"slope","axis","normal","direction"}
                variables.append((identity,key,i if isinstance(geometry[key],list) else None));start.append(float(value) if directional else float(value)/scale)
                lower.append(1e-12 if key=="radius" else -np.inf);upper.append(np.inf)
    if not variables:return _constrain(members,constraints)
    def unpack(values):
        result=copy.deepcopy(members);items={m["id"]:m["geometry"] for m in result}
        for (identity,key,index),value in zip(variables,values):
            physical=float(value if key in {"slope","axis","normal","direction"} else value*scale)
            if index is None:items[identity][key]=physical
            else:items[identity][key][index]=physical
        for geometry in items.values():
            for key in ("axis","normal","direction"):
                if key in geometry and np.linalg.norm(geometry[key])>1e-12:geometry[key]=_unit(geometry[key]).tolist()
        return _constrain(result,constraints)
    def residual(values):
        current=unpack(values);result=[]
        for member in current:
            data=data_byid[member["id"]];r=_residual(member["geometry"],data["points"])
            if r is not None:result.extend(r*np.sqrt(data["weights"])/scale)
        _,soft=_constraint_reports(current,constraints,scale)
        for record in soft:
            c=record["constraint"];weight=float(c.get("weight",1))
            if not math.isfinite(weight) or weight<0:raise EvidenceError("INVALID_CONSTRAINT","Soft weights must be finite nonnegative")
            physical=c["kind"] in {"equal_radius","concentric"} or c["kind"]=="fixed" and c.get("parameter") not in {"axis","normal","direction","slope","half_angle"}
            result.append(math.sqrt(weight)*record["residual"]/(scale if physical else 1.))
        return np.asarray(result)
    answer=least_squares(residual,start,bounds=(lower,upper),max_nfev=80,loss="soft_l1",f_scale=1e-4)
    return unpack(answer.x)


def _recognized_candidates(context,records,requested,constraints,limit,tolerance,provenance):
    """Consume optional recognizer output as alternatives, never a solid union."""
    choices=[];diagnostics=[]
    for evidence in records:
        if evidence.get("context_ref")!=context["id"] or evidence.get("source_hash")!=context["source_hash"]:
            raise EvidenceError("STALE_REFERENCE","Recognized evidence belongs to another source context")
        supported=[]
        for entry in evidence["recognition_records"]:
            family=entry["family"]
            if family not in requested:continue
            report=copy.deepcopy(entry["fit_report"])
            error=report["source_vertex_maximum"]
            if error>tolerance and not context.get("fit_policy",{}).get("allow_partial",False):continue
            report.update(source_vertex_or_fit_sample_maximum=error,recognized_region_ref=entry["id"])
            supported.append({"id":"member-"+_hash([evidence["id"],entry["id"]])[:20],"evidence_id":evidence["id"],"role":evidence.get("role",entry["id"]),
                              "family":family,"geometry":copy.deepcopy(entry["geometry"]),"observed_extent":copy.deepcopy(entry["observed_extent"]),
                              "inferred_extent":{"material_role":"unknown","terminal_faces":"unresolved","unobserved_trims":"unresolved"},
                              "fit_report":report,"conditioning_report":{"method":"bounded_regional_recognition","unique_original_design":False},
                              "supporting_triangle_ids":entry["triangle_ids"],"recognition_record_id":entry["id"],"recognition_area":entry["area"]})
        if not supported:
            return {"status":"no_result","payload":[],"diagnostics":[diagnostic("NO_ACCEPTABLE_FIT","No recognized region matches the requested families and local fitting policy",evidence_refs=[evidence["id"]])],"provenance":provenance}
        choices.append(supported)
    count=math.prod(len(items) for items in choices)
    if count>64:diagnostics.append(diagnostic("BUDGET_EXHAUSTED",f"Regional joint alternatives evaluate 64 of {count} combinations"))
    candidates=[]
    for chosen in itertools.islice(itertools.product(*choices),64):
        members=copy.deepcopy(list(chosen));compiled=[];hard=[];soft=[]
        if constraints:
            # Regional recognition has already fitted finite source support.
            # Do not move a specialized fit under a constraint without a new
            # source-residual implementation. Exact existing fixed values are
            # useful and can be checked independently without changing it.
            compiled=_compile_constraints(constraints,members,None)
            if any(c["kind"]!="fixed" for c in compiled):
                diagnostics.append(diagnostic("UNSUPPORTED_RECOGNITION_CONSTRAINT","Regional recognition alternatives currently support checking existing fixed values only; use a targeted primitive fit for relational refinement"));continue
            hard,soft=_constraint_reports(members,compiled,_analysis(context)["scale"])
            if any(not item["satisfied"] for item in hard):
                diagnostics.append(diagnostic("RECOGNITION_REFIT_UNSUPPORTED","A changed fixed value requires refitting the recognized surface, which is not implemented; use a targeted ordinary primitive fit or an explicit authored construction"))
                continue
        support={tid for member in members for tid in member["supporting_triangle_ids"]}
        observed={tid for record in records for tid in record["source_selection"]["triangle_ids"]}
        unresolved=[{"triangle_id":tid,"category":"not_supported_by_this_alternative"} for tid in sorted(observed-support)]
        dependencies={"source_hash":context["source_hash"],"evidence_dependencies":[record.get("dependencies",{}) for record in records]}
        candidate={"context_revision":context["id"],"context_ref":context["id"],"source_hash":context["source_hash"],"source_revision":context["id"],"based_on_revision":None,
                   "evidence_ids":[record["id"] for record in records],"family":members[0]["family"] if len(members)==1 else "joint","members":members,
                   "parameter_values":{m["id"]:m["geometry"] for m in members},"hard_constraint_report":hard,"soft_constraint_report":soft,"shared_parameters":[],
                   "semantic_bindings":{m["role"]:m["id"] for m in members},"supported_evidence":[m["evidence_id"] for m in members],"unresolved_evidence":unresolved,
                   "observed_extent":{m["id"]:m["observed_extent"] for m in members},"inferred_extensions":{m["id"]:m["inferred_extent"] for m in members},
                   "fit_report":{"guarantee":"sampled_local_fit_only","distance_tolerance":tolerance,"public_max_deviation":context.get("max_deviation"),"recognition_does_not_decide_material":True},
                   "conditioning_report":{m["id"]:m["conditioning_report"] for m in members},"complexity":{"members":len(members),"representation":"analytic_or_compact_line_arc_profile"},
                   "dependencies":dependencies,"dependency_fingerprint":_hash(dependencies),"units":"mm","provenance":provenance}
        candidate["id"]="fit-"+_hash(candidate)[:24];candidates.append(candidate)
    candidates.sort(key=lambda c:(-sum(m["recognition_area"] for m in c["members"]),len(c["unresolved_evidence"]),c["id"]))
    if not candidates:return {"status":"no_result","payload":[],"diagnostics":diagnostics or [diagnostic("CONSTRAINT_CONFLICT","No recognized alternative satisfies the requested checked constraints")],"provenance":provenance}
    return {"status":"partial" if diagnostics or any(c["unresolved_evidence"] for c in candidates) else "ok","payload":candidates[:limit],"diagnostics":diagnostics,"provenance":provenance}


def fit(context,evidence_records,families="auto",constraints=(),resolve_reference=None):
    provenance={"context_ref":context.get("id") if isinstance(context,dict) else None,"source_hash":context.get("source_hash") if isinstance(context,dict) else None,
                "dependency_revisions":[],"parameters":{"families":families,"constraints":constraints},"algorithm_versions":{"fit":VERSION},"seed":context.get("seed",0) if isinstance(context,dict) else 0}
    try:
        analysis=_analysis(context);policy=context.get("fit_policy",context.get("policy",{}).get("fit_policy",{}))
        if not isinstance(policy,dict):raise EvidenceError("INVALID_POLICY","fit_policy must be an object")
        if set(policy)-{"sample_budget","max_candidates","distance_tolerance","allow_partial"}:raise EvidenceError("INVALID_POLICY","Unknown fit_policy field")
        if type(policy.get("allow_partial",False)) is not bool:raise EvidenceError("INVALID_POLICY","allow_partial must be boolean")
        maximum=policy.get("sample_budget",2048);limit=policy.get("max_candidates",3)
        if type(maximum) is not int or not 16<=maximum<=10000 or type(limit) is not int or not 1<=limit<=16:raise EvidenceError("INVALID_POLICY","Fit sample budget must be16..10000 and candidate count1..16")
        records=evidence_records if isinstance(evidence_records,list) else [evidence_records]
        if not 1<=len(records)<=16 or not all(isinstance(record,dict) for record in records):raise EvidenceError("INVALID_EVIDENCE","Fit requires1..16 immutable evidence records")
        requested=set(SUPPORTED|RECOGNIZED) if families=="auto" else {families} if isinstance(families,str) else set(families)
        diagnostics=[diagnostic("UNSUPPORTED_FAMILY",f"No implemented fitter for {name}") for name in requested-(SUPPORTED|RECOGNIZED)]
        requested &= SUPPORTED|RECOGNIZED
        if not isinstance(constraints,(list,tuple)) or len(constraints)>128:raise EvidenceError("INVALID_CONSTRAINT","Constraints must be a bounded list")
        dependencies=[];options=[];all_data=[]
        tolerance=float(policy.get("distance_tolerance",max(float(context.get("max_deviation",0)),analysis["scale"]*1e-6)))
        if not math.isfinite(tolerance) or tolerance<=0:raise EvidenceError("INVALID_POLICY","Local fitting tolerance must be finite positive")
        if all("recognition_records" in record for record in records):
            result=_recognized_candidates(context,records,requested,constraints,limit,tolerance,provenance)
            result["diagnostics"]=diagnostics+result["diagnostics"]
            if diagnostics and result["status"]=="ok":result["status"]="partial"
            return result
        if any("recognition_records" in record for record in records):
            return {"status":"no_result","payload":[],"diagnostics":diagnostics+[diagnostic("UNSUPPORTED_MIXED_EVIDENCE","Fit recognized regional evidence separately from ordinary selections or sections. Use the resulting explicit tools in an atomic edit group; mixed joint regional refinement is not implemented.")],"provenance":provenance}
        if requested&RECOGNIZED and families!="auto":diagnostics.append(diagnostic("RECOGNITION_EVIDENCE_REQUIRED","Specialized regional families require evidence from inspect kind=recognize; ordinary fitting never starts expensive recognition implicitly"))
        for record in records:
            if record.get("context_ref")!=context["id"] or record.get("source_hash")!=context["source_hash"]:raise EvidenceError("STALE_REFERENCE","Fit evidence belongs to a different source context")
            identity=record.get("id",record.get("evidence_id"))
            if not isinstance(identity,str):raise EvidenceError("INVALID_EVIDENCE","Evidence must have an immutable ID")
            dependencies.append(record.get("dependencies",{}));data=_samples(context,record,maximum);all_data.append(data)
            center=np.average(data["points"],axis=0,weights=data["weights"]);scale=max(float(np.linalg.norm(np.ptp(data["points"],axis=0))),analysis["scale"]*1e-6)
            fits=[]
            family_order=[name for name in ("plane","line","circle","cylinder","cone","sphere","profile","extrusion","revolution") if name in requested]
            for family in family_order:
                if family in ("profile","extrusion","revolution"):
                    if family=="revolution" and families=="auto" and fits and not record.get("sections"):continue
                    generated=_generated_candidate(family,record,tolerance,context,data)
                    if generated:
                        geometry,error=generated
                        fits.append({"id":"member-"+_hash([identity,family])[:20],"evidence_id":identity,"role":record.get("role",identity),"family":family,"geometry":geometry,
                                     "observed_extent":{"classification":"observed_sections","terminal_faces_observed":False},"inferred_extent":{"closure":"none_inferred","end_caps":"unresolved"},
                                     "fit_report":{"sampled_maximum":error,"guarantee":"sampled_section_fit"},"conditioning_report":{"ambiguous_parameters":["unobserved_extents"]}})
                    elif family=="revolution":diagnostics.append(diagnostic("INSUFFICIENT_EVIDENCE","Revolution fitting requires several meridian observations and a resolved axis; arbitrary revolution inference is unavailable",evidence_refs=[identity]))
                    continue
                best=None
                for geometry in _primitive_starts(family,data,center,scale):
                    geometry,solver=_optimize_primitive(geometry,data,scale);report=_stats(geometry,data)
                    score=report["area_weighted_rms"]
                    if best is None or score<best[0]:best=(score,geometry,solver,report)
                if best is None:continue
                score,geometry,solver,report=best
                if report["source_vertex_or_fit_sample_maximum"]>tolerance and not policy.get("allow_partial",False):continue
                ambiguity=[];extent=_extent(geometry,data)
                if solver.get("condition_ratio",1)<1e-5:ambiguity.append("poor_parameter_identifiability")
                if family=="cylinder" and extent.get("angular_span",0)<math.pi/3:ambiguity.append("radius_and_axis_weakly_determined_on_short_arc")
                if family=="sphere":
                    span=extent.get("direction_span_singular_values",[0,0,0])
                    if len(span)<3 or span[-1]<max(span[0],1e-30)*.05:ambiguity.append("small_cap_or_ring_does_not_identify_sphere_uniquely")
                fits.append({"id":"member-"+_hash([identity,family])[:20],"evidence_id":identity,"role":record.get("role",identity),"family":family,"geometry":geometry,
                             "observed_extent":extent,"inferred_extent":{"support_surface":"unbounded_continuation","terminal_faces":"unresolved","material_role":"unknown"},
                             "fit_report":report,"conditioning_report":{"solver":solver,"ambiguous_parameters":ambiguity}})
            if not fits:
                return {"status":"no_result","payload":[],"diagnostics":diagnostics+[diagnostic("NO_ACCEPTABLE_FIT","No attempted permitted family meets the selected evidence's local fitting policy",evidence_refs=[identity])],"provenance":provenance}
            fits.sort(key=lambda member:(member["fit_report"].get("area_weighted_rms",member["fit_report"].get("sampled_maximum",0)),len(json.dumps(member["geometry"]))))
            options.append(fits[:min(4,len(fits))])
        candidates=[]
        combination_count=math.prod(len(choices) for choices in options)
        if combination_count>64:diagnostics.append(diagnostic("BUDGET_EXHAUSTED",f"Joint search evaluates 64 of {combination_count} family combinations; unattempted alternatives remain unknown"))
        for chosen in itertools.islice(itertools.product(*options),64):
            members=copy.deepcopy(list(chosen))
            try:compiled=_compile_constraints(constraints,members,resolve_reference)
            except EvidenceError as error:
                if error.code=="INCOMPATIBLE_FAMILY":continue
                raise
            data_byid={member["id"]:data for member,data in zip(members,all_data)}
            if compiled:members=_joint_refine(members,data_byid,compiled,analysis["scale"])
            hard,soft=_constraint_reports(members,compiled,analysis["scale"])
            if any(not record["satisfied"] for record in hard):continue
            acceptable=True
            for member,data in zip(members,all_data):
                if member["family"] in {"profile","extrusion","revolution"}:continue
                member["fit_report"]=_stats(member["geometry"],data);member["observed_extent"]=_extent(member["geometry"],data)
                if member["fit_report"]["source_vertex_or_fit_sample_maximum"]>tolerance and not policy.get("allow_partial",False):acceptable=False
            if not acceptable:continue
            unresolved=[]
            for member,data in zip(members,all_data):
                if member["family"] not in {"profile","extrusion","revolution"}:
                    values=np.abs(_residual(member["geometry"],data["verification_points"]))
                    unresolved.extend({"triangle_id":tid,"distance":float(values[i]),"category":"original_vertex_check"} for i,tid in enumerate(data["verification_triangle_ids"]) if values[i]>tolerance)
            candidate={"context_revision":context["id"],"context_ref":context["id"],"source_hash":context["source_hash"],"source_revision":context["id"],
                       "based_on_revision":next((record.get("cad_revision") for record in records if record.get("cad_revision")),None),"evidence_ids":[record.get("id",record.get("evidence_id")) for record in records],
                       "family":members[0]["family"] if len(members)==1 else "joint","members":members,"parameter_values":{m["id"]:m["geometry"] for m in members},
                       "hard_constraint_report":hard,"soft_constraint_report":soft,"shared_parameters":[{"relationship":c} for c in compiled if c["kind"]!="fixed"],
                       "semantic_bindings":{m["role"]:m["id"] for m in members},"supported_evidence":[m["evidence_id"] for m in members],"unresolved_evidence":unresolved,
                       "observed_extent":{m["id"]:m["observed_extent"] for m in members},"inferred_extensions":{m["id"]:m["inferred_extent"] for m in members},
                       "fit_report":{"guarantee":"sampled_local_fit_only","distance_tolerance":tolerance,"public_max_deviation":context.get("max_deviation"),"robustly_excluded_source_remains_in_reference":True},
                       "conditioning_report":{m["id"]:m.get("conditioning_report",{}) for m in members},"complexity":{"members":len(members),"representation":"analytic_or_compact_line_arc_profile"},
                       "dependencies":{"source_hash":context["source_hash"],"evidence_dependencies":dependencies},"units":context.get("units","mm"),"provenance":provenance}
            candidate["dependency_fingerprint"]=_hash(candidate["dependencies"]);candidate["id"]="fit-"+_hash(candidate)[:24];candidates.append(candidate)
        if not candidates:return {"status":"no_result","payload":[],"diagnostics":diagnostics+[diagnostic("CONSTRAINT_CONFLICT" if constraints else "NO_ACCEPTABLE_FIT","No joint alternative satisfies hard constraints and local evidence obligations")],"provenance":provenance}
        candidates.sort(key=lambda candidate:(len(candidate["unresolved_evidence"]),sum(m["fit_report"].get("area_weighted_rms",m["fit_report"].get("sampled_maximum",0)) for m in candidate["members"]),candidate["id"]))
        return {"status":"partial" if diagnostics or any(c["unresolved_evidence"] for c in candidates) else "ok","payload":candidates[:limit],"diagnostics":diagnostics,"provenance":provenance}
    except (EvidenceError,ValueError,TypeError,KeyError,IndexError,np.linalg.LinAlgError) as error:
        conflict=getattr(error,"code",None)=="CONSTRAINT_CONFLICT"
        return {"status":"no_result" if conflict else "error","payload":[] if conflict else None,"diagnostics":[diagnostic(getattr(error,"code","NUMERICAL_FAILURE"),str(error),severity="warning" if conflict else "error")],"provenance":provenance}
