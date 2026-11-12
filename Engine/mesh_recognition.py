"""Optional bounded regional recognition on original mesh evidence.

The numerical recognizers originate in LAD's steppa branch. They return local
surface/profile explanations, never a solid or reconstruction acceptance.
No construction schema or execution pipeline is retained here.
"""
from __future__ import annotations

import copy
import math
import numpy as np
from scipy.optimize import least_squares

from mesh_reference import canonical_digest, connected_components

VERSION = "regional-recognition-1"
FAMILIES = {"plane", "sphere", "cylinder", "torus", "helical_sweep",
            "rounded_rectangle_extrusion", "concentric_spherical_shell"}


def _rounded(value):
    if isinstance(value, dict): return {k: _rounded(v) for k, v in value.items()}
    if isinstance(value, list): return [_rounded(v) for v in value]
    if isinstance(value, float): return round(value, 8)
    return value


def _canonical_direction(vector):
    vector = np.asarray(vector, float)
    vector = vector / np.linalg.norm(vector)
    return -vector if vector[int(np.argmax(np.abs(vector)))] < 0 else vector


def _frame(axis):
    axis = _canonical_direction(axis)
    reference = np.eye(3)[int(np.argmin(np.abs(axis)))]
    x = np.cross(reference, axis); x /= np.linalg.norm(x)
    return x, np.cross(axis, x), axis


def _circle(points):
    points = np.asarray(points, float)
    center = points.mean(axis=0); q = points-center
    matrix = np.column_stack((2*q, np.ones(len(q))))
    if len(points) < 3 or np.linalg.matrix_rank(matrix) < 3: return None
    answer = np.linalg.lstsq(matrix, np.sum(q*q, axis=1), rcond=None)[0]
    radius2 = float(answer[-1] + answer[:-1]@answer[:-1])
    if radius2 <= 0: return None
    origin, radius = center+answer[:-1], math.sqrt(radius2)
    return origin, radius, float(np.abs(np.linalg.norm(points-origin, axis=1)-radius).max())


def _axes(points, normals, areas, edges=None):
    candidates = []
    # Cap/large planar normals are stronger evidence than density-biased PCA.
    bins = {}
    for normal, area in zip(normals, areas):
        if area <= 0:
            continue
        direction = _canonical_direction(normal)
        key = tuple(np.round(direction, 5))
        old = bins.get(key, (0, direction))
        bins[key] = (old[0] + area, direction)
    candidates.extend(direction for _, direction in sorted(bins.values(), key=lambda item: -item[0])[:9])
    if edges:
        curved_bins = {}
        for uses in edges.values():
            if len(uses) != 2:
                continue
            first,second = uses[0][0],uses[1][0]
            product = float(normals[first]@normals[second])
            if not .85 < product < 1-1e-9:
                continue
            cross = np.cross(normals[first],normals[second])
            length = np.linalg.norm(cross)
            if length < 1e-8:
                continue
            direction = _canonical_direction(cross)
            key = tuple(np.round(direction,3))
            weight = min(float(areas[first]),float(areas[second]))
            previous = curved_bins.get(key,(0,direction))
            curved_bins[key] = (previous[0]+weight,direction)
        candidates.extend(direction for _,direction in sorted(curved_bins.values(),key=lambda item:-item[0])[:6])
    if len(points) > 3:
        sample = points[::max(1, len(points) // 4000)]
        _, vectors = np.linalg.eigh(np.cov((sample - sample.mean(axis=0)).T))
        candidates.extend(vectors.T)
    candidates.extend(np.eye(3))
    result = []
    for axis in candidates:
        axis = _canonical_direction(axis)
        if not any(abs(float(np.dot(axis, old))) > 1 - 1e-8 for old in result):
            result.append(axis)
    return result[:15]


def _sphere_evidence(points, triangles, normals, scale):
    """Deterministic, bounded multi-sphere RANSAC on original vertex evidence."""
    unique = np.unique(points[triangles].reshape(-1,3),axis=0)
    if len(unique) < 12:
        return []
    origin = (unique.min(axis=0)+unique.max(axis=0))/2
    normalized = (unique-origin)/scale
    sample = normalized[np.linspace(0,len(normalized)-1,min(6000,len(normalized)),dtype=int)]
    all_tri = (points[triangles]-origin)/scale
    centroids = all_tri.mean(axis=1)
    tolerance = 3e-7
    rng = np.random.default_rng(0x4C4144)
    available = np.arange(len(sample))
    result = []
    for _ in range(4):
        if len(available) < 12:
            break
        best = None
        for _trial in range(320):
            chosen = sample[rng.choice(available,4,replace=False)]
            matrix = 2*(chosen[1:]-chosen[0])
            if abs(float(np.linalg.det(matrix))) < 1e-8:
                continue
            center = np.linalg.solve(matrix,np.sum(chosen[1:]**2,axis=1)-np.sum(chosen[0]**2))
            radius = float(np.linalg.norm(chosen[0]-center))
            if not .002 < radius < 2 or np.linalg.norm(center) > 3:
                continue
            residual = np.abs(np.linalg.norm(sample-center,axis=1)-radius)
            ids = available[residual[available] <= tolerance]
            if best is None or len(ids) > len(best[0]):
                best = ids,center,radius
        if best is None or len(best[0]) < max(12,int(.008*len(sample))):
            break
        seed = sample[best[0]]
        fit = least_squares(lambda v: np.linalg.norm(seed-v[:3],axis=1)-v[3],
                            np.r_[best[1],best[2]],max_nfev=30)
        center,radius = fit.x[:3],float(fit.x[3])
        residual = np.abs(np.linalg.norm(sample-center,axis=1)-radius)
        available = available[residual[available] > tolerance]
        vertex_error = np.abs(np.linalg.norm(all_tri-center,axis=2)-radius)
        direction = centroids-center
        direction /= np.maximum(np.linalg.norm(direction,axis=1)[:,None],1e-30)
        normal_dot = np.sum(direction*normals,axis=1)
        support = np.flatnonzero((np.max(vertex_error,axis=1) <= tolerance) & (np.abs(normal_dot) >= math.cos(math.radians(12))))
        if len(support) < 12:
            continue
        covariance = normals[support].T@normals[support]
        spectrum = np.linalg.eigvalsh(covariance)
        if spectrum[0] <= spectrum[-1]*1e-7:
            # Two cylindrical rings are cospherical. A rank-two normal field
            # cannot identify that sphere; retain the evidence for cylinders
            # instead of inventing spherical curvature between the rings.
            continue
        model = {"kind":"sphere","center":(origin+center*scale).tolist(),"radius":radius*scale}
        midpoint_error = np.abs(np.linalg.norm(centroids[support]-center,axis=1)-radius)*scale
        result.append({"model":model,"triangle_ids":support.tolist(),
                       "source_vertex_maximum":float(vertex_error[support].max()*scale),
                       "triangle_centroid_maximum":float(midpoint_error.max()),
                       "orientation_agreement":int(np.sign(np.median(normal_dot[support])))})
    return result


def _circle_consensus(points, *, maximum=5, seed=0):
    """Several compact circles in a normalized 2D point set, without hulls."""
    if len(points) < 8:
        return []
    values = np.unique(points,axis=0)
    values = values[np.linspace(0,len(values)-1,min(len(values),4000),dtype=int)]
    available = np.arange(len(values))
    rng = np.random.default_rng(seed)
    result = []
    tolerance = 4e-7
    for _ in range(maximum):
        best = None
        if len(available) < 8:
            break
        for _trial in range(160):
            chosen = values[rng.choice(available,3,replace=False)]
            matrix = 2*(chosen[1:]-chosen[0])
            if abs(float(np.linalg.det(matrix))) < 1e-9:
                continue
            center = np.linalg.solve(matrix,np.sum(chosen[1:]**2,axis=1)-np.sum(chosen[0]**2))
            radius = float(np.linalg.norm(chosen[0]-center))
            if not .0001 < radius < 2 or np.linalg.norm(center) > 3:
                continue
            residual = np.abs(np.linalg.norm(values-center,axis=1)-radius)
            ids = available[residual[available] <= tolerance]
            if best is None or len(ids) > len(best[0]):
                best = ids,center,radius
        if best is None or len(best[0]) < max(8,int(.015*len(values))):
            break
        fit = _circle(values[best[0]])
        if fit is None:
            break
        center,radius,_error = fit
        result.append((center,radius))
        available = available[np.abs(np.linalg.norm(values[available]-center,axis=1)-radius) > tolerance]
    return result


def _cylinder_evidence(points, triangles, normals, areas, axes, scale, excluded, adjacency=None):
    result, seen = [], set()
    tri = points[triangles]
    centers = tri.mean(axis=1)
    origin = (points.min(axis=0)+points.max(axis=0))/2
    axes = list(axes)
    if adjacency is not None:
        smooth = [set() for _ in triangles]
        for first,neighbors in enumerate(adjacency):
            if excluded[first]:
                continue
            for second in neighbors:
                if not excluded[second] and float(normals[first]@normals[second]) > math.cos(math.radians(25)):
                    smooth[first].add(second)
        patches = connected_components(np.flatnonzero(~excluded),smooth)
        patches.sort(key=lambda tids:-float(areas[tids].sum()))
        for tids in patches[:24]:
            if len(tids) < 12:
                continue
            field = normals[tids]
            values,vectors = np.linalg.eigh((field*areas[tids,None]).T@field)
            if values[1] > 0 and values[0] < values[1]*1e-5 and values[1] > values[2]*.05:
                axis = _canonical_direction(vectors[:,0])
                if not any(abs(float(axis@old)) > 1-1e-8 for old in axes):
                    axes.insert(0,axis)
    for axis_index,axis in enumerate(axes):
        possible = (np.abs(normals@axis) < .002) & (areas > 0) & ~excluded
        ids = np.flatnonzero(possible)
        if len(ids) < 16:
            continue
        # Average many native facet planes to remove float32 normal jitter.
        covariance = (normals[ids]*areas[ids,None]).T@normals[ids]
        _,vectors = np.linalg.eigh(covariance)
        refined = _canonical_direction(vectors[:,0])
        if abs(float(refined@axis)) > .9999:
            axis = refined
        x,y,axis = _frame(axis)
        vertices = np.unique(tri[ids].reshape(-1,3),axis=0)
        coordinates = np.column_stack(((vertices-origin)@x,(vertices-origin)@y))/scale
        for circle,radius in _circle_consensus(coordinates,maximum=5,seed=axis_index+91):
            centerline = origin+scale*(x*circle[0]+y*circle[1])
            relative = tri-centerline
            axial = relative@axis
            radial = np.linalg.norm(relative-axial[:,:,None]*axis,axis=2)
            error = np.abs(radial-radius*scale)
            mask = possible & (np.max(error,axis=1) <= scale*6e-7)
            support = np.flatnonzero(mask)
            if len(support) < 16:
                continue
            low,high = float(axial[support].min()),float(axial[support].max())
            if high-low < scale*.001:
                continue
            # A tiny arc is retained as uncertainty, not a full-circle claim.
            angle_points = tri[support].reshape(-1,3)-centerline
            angles = np.arctan2(angle_points@y,angle_points@x)
            span = 2*math.pi-float(np.max(np.diff(np.r_[np.sort(angles),np.sort(angles)[0]+2*math.pi])))
            if span < math.radians(20):
                continue
            model = {"kind":"cylinder","origin":(centerline+axis*low).tolist(),
                     "axis":axis.tolist(),"radius":float(radius*scale),"height":high-low}
            signature = canonical_digest(_rounded(model))
            if signature in seen:
                continue
            seen.add(signature)
            direction = centers[support]-centerline
            direction -= (direction@axis)[:,None]*axis
            direction /= np.maximum(np.linalg.norm(direction,axis=1)[:,None],1e-30)
            signed = np.sum(direction*normals[support],axis=1)
            center_error = np.abs(np.linalg.norm((centers[support]-centerline)-((centers[support]-centerline)@axis)[:,None]*axis,axis=1)-radius*scale)
            result.append({"model":model,"triangle_ids":support.tolist(),"angular_span_degrees":math.degrees(span),
                           "source_vertex_maximum":float(error[support].max()),"triangle_centroid_maximum":float(center_error.max()),
                           "orientation_agreement":int(np.sign(np.median(signed)))})
    return result


def _coherent_regions(points, triangles, normals, areas, adjacency, axes, scale):
    """Partition original triangles into compact analytic or unresolved patches."""
    tri = points[triangles]
    # This recognition threshold covers binary STL coordinate roundoff. It is
    # independent of acceptance and never welds or alters source geometry.
    distance_tolerance = scale*3e-7
    angular_cosine = math.cos(math.radians(.06))
    remaining = set(range(len(triangles)))
    plane_groups = []
    for seed in np.argsort(-areas,kind="stable").tolist():
        if seed not in remaining:
            continue
        remaining.remove(seed)
        normal, anchor = normals[seed],tri[seed,0]
        stack, group = [seed],[seed]
        while stack:
            current = stack.pop()
            for neighbor in adjacency[current]:
                if neighbor not in remaining:
                    continue
                if abs(float(normals[neighbor]@normal)) < angular_cosine or np.max(np.abs((tri[neighbor]-anchor)@normal)) > distance_tolerance:
                    continue
                remaining.remove(neighbor)
                stack.append(neighbor)
                group.append(neighbor)
        plane_groups.append(sorted(group))
    evidence = _sphere_evidence(points,triangles,normals,scale) if len(triangles)>=24 else []
    excluded = np.zeros(len(triangles),dtype=bool)
    for item in evidence:
        excluded[item["triangle_ids"]] = True
    evidence.extend(_cylinder_evidence(points,triangles,normals,areas,axes,scale,excluded,adjacency) if len(triangles)>=32 else [])
    evidence.sort(key=lambda item:-float(areas[item["triangle_ids"]].sum()))
    assigned = np.zeros(len(triangles),dtype=bool)
    groups = []
    for item in evidence:
        tids = np.asarray(item["triangle_ids"],int)
        tids = tids[~assigned[tids]]
        if len(tids) < 12:
            continue
        for connected in connected_components(tids,adjacency):
            if len(connected) < 8:
                continue
            assigned[connected] = True
            groups.append((connected,item))
    for tids in plane_groups:
        # Substantial planar evidence becomes one region; isolated curved facets
        # are deferred to connected unresolved patches rather than thousands of
        # one-triangle pseudo-regions.
        area = float(areas[tids].sum())
        if len(tids) < 2 or area < scale*scale*1e-5 or len(tids) == 2 and area < scale*scale*.001:
            continue
        for connected in connected_components([t for t in tids if not assigned[t]],adjacency):
            if not connected:
                continue
            assigned[connected] = True
            sample = tri[connected].reshape(-1,3)
            center = sample.mean(axis=0)
            _,_,vectors = np.linalg.svd((sample-center)[::max(1,len(sample)//2000)],full_matrices=False)
            normal = _canonical_direction(vectors[-1])
            groups.append((connected,{"plane":{"normal":normal.tolist(),"offset":float(normal@center)}}))
    residual_adjacency = [set() for _ in triangles]
    for current,neighbors in enumerate(adjacency):
        if assigned[current]:
            continue
        for neighbor in neighbors:
            if not assigned[neighbor] and abs(float(normals[current]@normals[neighbor])) > math.cos(math.radians(25)):
                residual_adjacency[current].add(neighbor)
    for tids in connected_components(np.flatnonzero(~assigned),residual_adjacency):
        groups.append((tids,{}))
    regions,lookup = [],{}
    for tids,item in groups:
        tids = sorted(tids)
        identity = "region-"+canonical_digest(tids)[:20]
        for tid in tids:
            lookup[tid] = identity
        values = tri[tids].reshape(-1,3)
        plane = item.get("plane")
        region = {"id":identity,"triangle_ids":tids,"area":float(areas[tids].sum()),"normal":plane["normal"] if plane else None,
                  "plane":plane,"provisional":True,"surface_kind":item.get("model",{}).get("kind","plane" if plane else "unresolved_curved"),
                  "bounds":{"min":values.min(axis=0).tolist(),"max":values.max(axis=0).tolist()}}
        if "model" in item:
            region.update(analytic_model=item["model"],orientation_agreement=item["orientation_agreement"],
                          fit_error={"source_vertex_maximum":item["source_vertex_maximum"],"triangle_centroid_maximum":item["triangle_centroid_maximum"],"estimated":True})
            if "angular_span_degrees" in item:
                region["angular_span_degrees"] = item["angular_span_degrees"]
        regions.append(region)
    regions.sort(key=lambda entry:(-entry["area"],entry["id"]))
    return regions,lookup


def _frames(regions):
    """Bound axis search before plane-pair enumeration, including facet grids."""
    result=[]
    planes=[]
    for region in sorted(regions,key=lambda r:-r.get("area",0.)):
        if not region.get("plane"):continue
        axis=_canonical_direction(region["plane"]["normal"])
        if not any(abs(float(axis@old))>1-1e-8 for old in planes):planes.append(axis)
        if len(planes)>=24:break
    def append(axis,origin):
        axis=_canonical_direction(axis);origin=np.asarray(origin,float)
        origin=origin-axis*float(origin@axis)
        if len(result)<18 and not any(abs(float(axis@old))>1-1e-8 and np.linalg.norm(origin-point)<1e-6 for old,point in result):
            result.append((axis,origin))
    # Recognized cylinder axes are strongest. PCA/original-edge source hints
    # must precede a forest of normals from planar torus tessellation strips.
    for region in regions:
        model=region.get("analytic_model",{})
        if model.get("kind") in ("cylinder","cone","torus"):
            axis=_canonical_direction(model["axis"])
            for plane in planes:
                if abs(float(plane@axis))>1-1e-8:axis=plane;break
            append(axis,model.get("origin",model.get("center")))
    for region in regions:
        if region.get("axis_hint"):append(region["axis_hint"],region["axis_origin"])
    for normal in planes:append(normal,np.zeros(3))
    for i,a in enumerate(planes):
        for b in planes[i+1:]:
            if len(result)>=18:return result
            axis=np.cross(a,b)
            if np.linalg.norm(axis)>=.2:append(axis,np.zeros(3))
    return result


def refine_torus_regions(points,triangles,normals,areas,adjacency,regions,scale,frame_regions=None):
    tri = points[triangles]
    output = []
    frames = _frames(regions if frame_regions is None else frame_regions)
    for region in regions:
        if region.get("surface_kind") != "unresolved_curved" or len(region["triangle_ids"])<24:
            output.append(region)
            continue
        original = np.asarray(region["triangle_ids"],int)
        remaining = set(original.tolist())
        proposals = []
        for index,(axis,origin) in enumerate(frames):
            vertices = np.unique(tri[original].reshape(-1,3),axis=0)-origin
            axial = vertices@axis
            radial = np.linalg.norm(vertices-axial[:,None]*axis,axis=1)
            x,y,axis=_frame(axis)
            cylinder_circle=_circle(np.column_stack((vertices@x,vertices@y)))
            if cylinder_circle is not None and cylinder_circle[2]<scale*7e-7 and np.ptp(axial)>scale*.001:
                center2,radius,_error=cylinder_circle
                centerline=origin+x*center2[0]+y*center2[1]
                low,high=float(axial.min()),float(axial.max())
                model={"kind":"cylinder","origin":(centerline+axis*low).tolist(),"axis":axis.tolist(),"radius":radius,"height":high-low}
                proposals.append((float(areas[original].sum()),original,model))
            q = np.column_stack((radial,axial))/scale
            for center,radius in _circle_consensus(q,maximum=6,seed=index+611):
                if not .0001<radius<.5 or center[0]<=radius*1.01 or center[0]>2:
                    continue
                center3 = origin+axis*center[1]*scale
                diff = tri[original]-center3
                z = diff@axis
                rho = np.linalg.norm(diff-z[:,:,None]*axis,axis=2)
                error = np.abs(np.hypot(rho-center[0]*scale,z)-radius*scale)
                ids = original[np.max(error,axis=1)<scale*7e-7]
                if len(ids)<16:
                    continue
                middle = tri[ids].mean(axis=1)-center3
                height = middle@axis
                radial_vector = middle-height[:,None]*axis
                radial_length = np.linalg.norm(radial_vector,axis=1)
                direction = middle-center[0]*scale*radial_vector/np.maximum(radial_length[:,None],1e-30)
                direction /= np.maximum(np.linalg.norm(direction,axis=1)[:,None],1e-30)
                agreement = np.sum(direction*normals[ids],axis=1)
                ids = ids[np.abs(agreement)>.97]
                if len(ids)<16:
                    continue
                model = {"kind":"torus","center":center3.tolist(),"axis":axis.tolist(),
                         "major_radius":float(center[0]*scale),"minor_radius":float(radius*scale)}
                proposals.append((float(areas[ids].sum()),ids,model))
        for _,ids,model in sorted(proposals,key=lambda item:-item[0]):
            available = sorted(set(ids.tolist())&remaining)
            for connected in connected_components(available,adjacency):
                if len(connected)<12:
                    continue
                remaining.difference_update(connected)
                values = tri[connected].reshape(-1,3)
                axis = np.asarray(model["axis"]);reference=model.get("center",model.get("origin"));relative=values-reference
                axial = relative@axis;radial=np.linalg.norm(relative-axial[:,None]*axis,axis=1)
                vertex_error = np.abs(radial-model["radius"]) if model["kind"]=="cylinder" else np.abs(np.hypot(radial-model["major_radius"],axial)-model["minor_radius"])
                middle=tri[connected].mean(axis=1)-reference;height=middle@axis
                vector=middle-height[:,None]*axis;length=np.linalg.norm(vector,axis=1)
                direction=vector if model["kind"]=="cylinder" else middle-model["major_radius"]*vector/np.maximum(length[:,None],1e-30)
                deviation=np.abs(length-model["radius"]) if model["kind"]=="cylinder" else np.abs(np.linalg.norm(direction,axis=1)-model["minor_radius"])
                direction/=np.maximum(np.linalg.norm(direction,axis=1)[:,None],1e-30)
                output.append({"id":"region-"+canonical_digest(connected)[:20],"triangle_ids":connected,"area":float(areas[connected].sum()),
                               "surface_kind":model["kind"],"analytic_model":model,"normal":None,"plane":None,"provisional":True,
                               "orientation_agreement":int(np.sign(np.median(np.sum(direction*normals[connected],axis=1)))),
                               "fit_error":{"source_vertex_maximum":float(vertex_error.max()),"triangle_centroid_maximum":float(deviation.max()),"estimated":True},
                               "bounds":{"min":values.min(axis=0).tolist(),"max":values.max(axis=0).tolist()}})
        for connected in connected_components(remaining,adjacency):
            item = copy.deepcopy(region)
            item.update(id="region-"+canonical_digest(connected)[:20],triangle_ids=connected,area=float(areas[connected].sum()))
            values=tri[connected].reshape(-1,3)
            item["bounds"]={"min":values.min(axis=0).tolist(),"max":values.max(axis=0).tolist()}
            output.append(item)
    output.sort(key=lambda item:(-item["area"],item["id"]))
    return output


def helical_profile_evidence(points,triangles,normals,regions,scale):
    tri=points[triangles];middle=tri.mean(axis=1)
    flanks=[]
    for axis,origin in _frames(regions):
        x,y,axis=_frame(axis)
        for region in regions:
            if region.get("surface_kind")!="unresolved_curved" or len(region["triangle_ids"])<40:
                continue
            tids=np.asarray(region["triangle_ids"],int);normal=normals[tids]
            relative=middle[tids]-origin;denominator=normal@axis
            numerator=np.sum(normal*np.cross(axis,relative),axis=1)
            good=np.abs(denominator)>.15
            if good.sum()<20:
                continue
            pitch_values=-2*math.pi*numerator[good]/denominator[good]
            pitch=float(np.median(pitch_values));mad=float(np.median(np.abs(pitch_values-pitch)))
            if not scale*1e-4<abs(pitch)<scale*.5 or mad>abs(pitch)*.5:
                continue
            vertices=np.unique(tri[tids].reshape(-1,3),axis=0)-origin
            axial=vertices@axis;radial_vector=vertices-axial[:,None]*axis
            radial=np.linalg.norm(radial_vector,axis=1);angle=np.arctan2(radial_vector@y,radial_vector@x)
            if np.ptp(radial)<scale*1e-4 or np.ptp(axial)<abs(pitch)*.8:
                continue
            cycles=axial/pitch-angle/(2*math.pi)
            anchor=float(np.angle(np.mean(np.exp(cycles*2j*math.pi)))/(2*math.pi))
            def phase(p):return (axial/p-angle/(2*math.pi)-anchor+.5)%1-.5
            slope,intercept=np.linalg.lstsq(np.column_stack((phase(pitch),np.ones(len(radial)))),radial,rcond=None)[0]
            initial=[pitch,slope,intercept]
            bounds=([pitch*.85,-scale*4,-scale*4],[pitch*1.15,scale*4,scale*4]) if pitch>0 else ([pitch*1.15,-scale*4,-scale*4],[pitch*.85,scale*4,scale*4])
            fit=least_squares(lambda value:(radial-(value[1]*phase(value[0])+value[2]))/scale,initial,bounds=bounds,max_nfev=80,ftol=1e-12,xtol=1e-12,gtol=1e-12)
            error=np.abs(fit.fun)*scale
            if not fit.success or error.max()>scale*8e-7:
                continue
            pitch=float(fit.x[0]);phase_value=pitch*(phase(pitch)+anchor)
            phase_value-=math.floor(float(phase_value.min())/abs(pitch))*abs(pitch)
            if np.ptp(phase_value)>abs(pitch)*.8:
                continue
            flanks.append({"region_ids":[region["id"]],"triangle_ids":region["triangle_ids"],"axis":axis.tolist(),"axis_origin":origin.tolist(),
                           "x_direction":x.tolist(),"pitch":abs(pitch),"handedness":"right" if pitch>0 else "left",
                           "phase_interval":[float(phase_value.min()),float(phase_value.max())],"radial_interval":[float(radial.min()),float(radial.max())],
                           "axial_interval":[float(axial.min()),float(axial.max())],"radial_slope":float(fit.x[1]/pitch),
                           "fit_error":{"source_vertex_maximum":float(error.max()),"source_vertex_rms":float(np.sqrt(np.mean(error**2))),"estimated":True}})
    features=[];used=set()
    for first in flanks:
        for second in flanks:
            if first is second or first["radial_slope"]*second["radial_slope"]>=0 or first["handedness"]!=second["handedness"]:
                continue
            if abs(first["pitch"]-second["pitch"])>scale*1e-5 or np.linalg.norm(np.asarray(first["axis"])-second["axis"])>1e-4 or np.linalg.norm(np.asarray(first["axis_origin"])-second["axis_origin"])>scale*1e-5:
                continue
            if np.max(np.abs(np.asarray(first["radial_interval"])-second["radial_interval"]))>scale*1e-5:
                continue
            a,b=(first,second) if first["radial_slope"]>0 else (second,first)
            pitch=(a["pitch"]+b["pitch"])/2
            b=copy.deepcopy(b)
            shift=math.ceil((a["phase_interval"][1]-b["phase_interval"][0])/pitch)*pitch
            b["phase_interval"]=[value+shift for value in b["phase_interval"]]
            if a["phase_interval"][1]>=b["phase_interval"][0] or b["phase_interval"][1]>a["phase_interval"][0]+pitch:
                continue
            identities=sorted(a["region_ids"]+b["region_ids"])
            identity="helical-profile-"+canonical_digest(identities)[:20]
            if identity in used:continue
            used.add(identity)
            r0=(a["radial_interval"][0]+b["radial_interval"][0])/2;r1=(a["radial_interval"][1]+b["radial_interval"][1])/2
            low=min(a["axial_interval"][0],b["axial_interval"][0]);high=max(a["axial_interval"][1],b["axial_interval"][1]);pitch=(a["pitch"]+b["pitch"])/2
            # Phase is in the world-axis coordinate convention. Account for
            # translating the constructor's origin to the observed lower end.
            shift=low%pitch
            profile=[[r0,a["phase_interval"][0]-shift],[r1,a["phase_interval"][1]-shift],
                     [r1,b["phase_interval"][0]-shift],[r0,b["phase_interval"][1]-shift]]
            model={"kind":"helical_sweep","origin":(np.asarray(a["axis_origin"])+np.asarray(a["axis"])*low).tolist(),
                   "axis":a["axis"],"x_direction":a["x_direction"],"pitch":pitch,"height":high-low,"handedness":a["handedness"],
                   "phase_degrees":0.,"profile":{"outer":profile,"holes":[]}}
            features.append({"id":identity,"kind":"helical_radial_profile","region_ids":identities,"model":model,"flanks":[a,b],
                             "baseline_radius":r0,"radial_range":[r0,r1],"axial_interval":[low,high],
                             "construction_role":"boundary evidence; groove tool needs a separately constructed core and material-side interpretation",
                             "fit_error":{"source_vertex_maximum":max(a["fit_error"]["source_vertex_maximum"],b["fit_error"]["source_vertex_maximum"]),"estimated":True}})
    return features


def _section_loops(points,triangles,axis,level,x,y):
    """Join only identical original-edge intersection events, never near gaps."""
    unique,reverse=np.unique(points,axis=0,return_inverse=True)
    welded=reverse[triangles];values=unique@axis-level
    events={};segments=set()
    for face in welded:
        signs=values[face]
        if np.min(signs)>0 or np.max(signs)<0:continue
        if np.count_nonzero(signs==0)>1:return []
        keys=[]
        for first,second in zip(face,np.roll(face,-1)):
            a,b=values[first],values[second]
            if a==0:
                key=("v",int(first));position=unique[first]
            elif a*b<0:
                key=("e",int(min(first,second)),int(max(first,second)))
                position=unique[first]+a/(a-b)*(unique[second]-unique[first])
            else:continue
            events[key]=np.array([position@x,position@y]);keys.append(key)
        keys=list(dict.fromkeys(keys))
        if len(keys)==2:segments.add(tuple(sorted(keys)))
    neighbors={}
    for a,b in segments:neighbors.setdefault(a,set()).add(b);neighbors.setdefault(b,set()).add(a)
    if not neighbors or any(len(value)!=2 for value in neighbors.values()):return []
    remaining=set(neighbors);loops=[]
    while remaining:
        first=min(remaining);current=first;previous=None;loop=[]
        while current in remaining:
            remaining.remove(current);loop.append(events[current]);following=sorted(neighbors[current]-({previous} if previous else set()))
            previous,current=current,following[0]
        if current!=first:return []
        if len(loop)>=8:loops.append(np.asarray(loop))
    return loops


def _rounded_rectangle(loop,scale):
    center=loop.mean(axis=0);_,vectors=np.linalg.eigh(np.cov((loop-center).T));direction=vectors[:,-1]
    angle=math.atan2(direction[1],direction[0]);rotation=np.array([[math.cos(angle),-math.sin(angle)],[math.sin(angle),math.cos(angle)]])
    local=(loop-center)@rotation;low,high=local.min(axis=0),local.max(axis=0)
    center+=rotation@((low+high)/2);width,height=high-low
    if min(width,height)<scale*1e-4:return None
    minimum=min(width,height)
    def residual(v):
        c=v[:2];w,h,r=v[2:5];a=v[5];rot=np.array([[math.cos(a),-math.sin(a)],[math.sin(a),math.cos(a)]])
        q=np.abs((loop-c)@rot)-np.array([w/2-r,h/2-r])
        return (np.linalg.norm(np.maximum(q,0),axis=1)+np.minimum(np.maximum(q[:,0],q[:,1]),0)-r)/scale
    initial=np.r_[center,width,height,minimum/4,angle]
    fit=least_squares(residual,initial,bounds=(np.r_[center-scale,width*.7,height*.7,minimum*.02,angle-.4],
                                             np.r_[center+scale,width*1.3,height*1.3,minimum*.4999,angle+.4]),max_nfev=100,ftol=1e-11,xtol=1e-11,gtol=1e-11)
    error=np.abs(fit.fun)*scale;c=fit.x[:2];w,h,r,a=fit.x[2:]
    if not fit.success or error.max()>scale*2e-5 or r>=min(w,h)*.49 or min(w-2*r,h-2*r)<scale*.001:
        return None
    return {"center":c.tolist(),"width":float(w),"height":float(h),"corner_radius":float(r),"angle_radians":float(a),
            "sampled_maximum":float(error.max()),"sampled_rms":float(np.sqrt(np.mean(error**2))),"sample_count":len(loop)}


def _rounded_profile(rectangle):
    c=np.asarray(rectangle["center"]);w,h,r=rectangle["width"],rectangle["height"],rectangle["corner_radius"];a=rectangle["angle_radians"]
    rot=np.array([[math.cos(a),-math.sin(a)],[math.sin(a),math.cos(a)]])
    corners=[np.array([w/2-r,-h/2+r]),np.array([w/2-r,h/2-r]),np.array([-w/2+r,h/2-r]),np.array([-w/2+r,-h/2+r])]
    starts=[-math.pi/2,0,math.pi/2,math.pi];arcs=[]
    transform=lambda p:(c+rot@p).tolist()
    for corner,start in zip(corners,starts):
        positions=[transform(corner+r*np.array([math.cos(v),math.sin(v)])) for v in (start,start+math.pi/4,start+math.pi/2)]
        arcs.append({"kind":"arc","start":positions[0],"mid":positions[1],"end":positions[2]})
    segments=[]
    for i,arc in enumerate(arcs):
        segments.append(arc);segments.append({"kind":"line","start":arc["end"],"end":arcs[(i+1)%4]["start"]})
    return {"outer":{"segments":segments},"holes":[]}


def rounded_extrusion_evidence(points,triangles,regions,scale):
    tri=points[triangles];features=[];seen=set();seeds=list(regions)
    corner_groups={}
    for region in regions:
        model=region.get("analytic_model",{})
        if model.get("kind")!="cylinder" or model["radius"]>scale*.05:continue
        axis=np.asarray(model["axis"]);axis/=np.linalg.norm(axis)
        key=tuple(np.round(np.r_[axis,model["radius"]/scale],4))
        corner_groups.setdefault(key,[]).append(region)
    for values in corner_groups.values():
        if not 4<=len(values)<=12:continue
        tids=sorted({tid for region in values for tid in region["triangle_ids"]})
        local=tri[tids].reshape(-1,3)
        if np.linalg.norm(np.ptp(local,axis=0))<scale*.35:
            seeds.append({"surface_kind":"unresolved_curved","triangle_ids":tids,"id":"parallel-corner-constellation"})
    # Localized unresolved components are where a rounded cut can hide among
    # sphere intersections and blend surfaces; large body sections are not a
    # substitute for matching its repeated local profiles.
    for region in seeds:
        if region.get("surface_kind")!="unresolved_curved" or len(region["triangle_ids"])<100:continue
        local=tri[region["triangle_ids"]].reshape(-1,3)
        if np.linalg.norm(np.ptp(local,axis=0))>scale*.35:continue
        nearby=[]
        for plane in regions:
            if not plane.get("plane"):continue
            bounds=plane.get("bounds",{});lo=np.asarray(bounds.get("min",[-np.inf]*3));hi=np.asarray(bounds.get("max",[np.inf]*3))
            if np.any(hi<local.min(axis=0)-scale*.01) or np.any(lo>local.max(axis=0)+scale*.01):continue
            normal=np.asarray(plane["plane"]["normal"])
            if not any(abs(float(normal@old))>1-1e-8 for old in nearby):nearby.append(normal)
        candidates=[]
        for first in nearby:
            for second in nearby:
                axis=np.cross(first,second);length=np.linalg.norm(axis)
                if length<.2:continue
                axis/=length
                if not any(abs(float(axis@old))>1-1e-8 for old in candidates):candidates.append(axis)
        if not candidates:continue
        for axis in candidates[:4]:
            x,y,axis=_frame(axis);levels=local@axis;low,high=float(levels.min()),float(levels.max())
            if high-low<scale*.005:continue
            # An opening cut into a curved shell need not have one unoccluded
            # section containing its complete profile. Pool only native side
            # facets parallel to the extrusion axis, retaining their 3D scope.
            vectors=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);lengths=np.linalg.norm(vectors,axis=1)
            vectors/=np.maximum(lengths[:,None],1e-30)
            centers=tri.mean(axis=1)
            mask=(np.abs(vectors@axis)<.003)&np.all(centers>=local.min(axis=0)-scale*.002,axis=1)&np.all(centers<=local.max(axis=0)+scale*.002,axis=1)
            owned=np.flatnonzero(mask)
            if len(owned)>=16:
                samples=np.unique(tri[owned].reshape(-1,3),axis=0)
                projected=np.column_stack((samples@x,samples@y))
                fit=_rounded_rectangle(projected,scale)
                if fit is not None:
                    a=fit["angle_radians"];rot=np.array([[math.cos(a),-math.sin(a)],[math.sin(a),math.cos(a)]])
                    q=(projected-fit["center"])@rot
                    corner=(np.abs(q[:,0])>fit["width"]/2-fit["corner_radius"]*.9)&(np.abs(q[:,1])>fit["height"]/2-fit["corner_radius"]*.9)
                    signs={tuple(np.sign(row)) for row in q[corner]}
                    if len(signs)==4 and corner.sum()>=12:
                        key=tuple(np.round(np.r_[axis,fit["center"],fit["width"],fit["height"],fit["corner_radius"]],4))
                        if key not in seen:
                            seen.add(key);identity="rounded-extrusion-"+canonical_digest(list(key))[:20]
                            source_regions=[entry["id"] for entry in regions if set(entry["triangle_ids"])&set(owned.tolist())]
                            features.append({"id":identity,"kind":"rounded_rectangle_extrusion","region_ids":source_regions,"axis":axis.tolist(),"x_direction":x.tolist(),
                                             "profile":_rounded_profile(fit),"dimensions":{k:fit[k] for k in ("center","width","height","corner_radius","angle_radians")},
                                             "parallel_side_triangle_ids":owned.tolist(),"observed_axial_interval":[low,high],
                                             "fit_error":{"source_profile_maximum":fit["sampled_maximum"],"estimated":True},
                                             "evidence_method":"axis-parallel bounded side facets across multiple axial positions; all four rounded corners observed",
                                             "construction_role":"localized subtractive profile; shell intersections bound visible wall extents and adjacent blends remain separate"})
                            continue
            found=[]
            for fraction in (.25,.375,.5,.625,.75):
                level=low+(high-low)*fraction+scale*1.234e-7
                for loop in _section_loops(points,triangles,axis,level,x,y):
                    center_world=x*np.mean(loop[:,0])+y*np.mean(loop[:,1])+axis*level
                    if np.any(center_world<local.min(axis=0)-scale*.01) or np.any(center_world>local.max(axis=0)+scale*.01):continue
                    fit=_rounded_rectangle(loop,scale)
                    if fit is not None:found.append((level,fit))
            for index,(level,fit) in enumerate(found):
                matches=[(z,other) for z,other in found if abs(z-level)>scale*1e-4 and np.linalg.norm(np.asarray(other["center"])-fit["center"])<scale*5e-5
                         and np.max(np.abs(np.asarray([other["width"],other["height"],other["corner_radius"]])-[fit["width"],fit["height"],fit["corner_radius"]]))<scale*5e-5]
                if not matches:continue
                key=tuple(np.round(np.r_[axis,fit["center"],fit["width"],fit["height"],fit["corner_radius"]],4))
                if key in seen:continue
                seen.add(key)
                identity="rounded-extrusion-"+canonical_digest(list(key))[:20]
                measured=[(level,fit)]+matches
                profile=_rounded_profile(fit)
                features.append({"id":identity,"kind":"rounded_rectangle_extrusion","region_ids":[region["id"]],"axis":axis.tolist(),"x_direction":x.tolist(),
                                 "profile":profile,"dimensions":{k:fit[k] for k in ("center","width","height","corner_radius","angle_radians")},
                                 "matching_sections":[{"axis_coordinate":z,**item} for z,item in measured],
                                 "observed_axial_interval":[low,high],"fit_error":{"section_maximum":max(item["sampled_maximum"] for _,item in measured),"estimated":True},
                                 "construction_role":"repeated profile of a localized opening; extend a subtractive tool only to independently verified exterior/cavity bounds; adjacent blends remain separate"})
                break
    return features


def recognize(context, analysis, selection, families="auto", *, triangle_budget=100000):
    """Recognize compact regions without extending clipped/source scope.

    Work uses complete original triangles only. Barycentric clips and unvisited
    triangles remain explicit unknowns rather than being widened into support.
    """
    from mesh_inspect import EvidenceError, diagnostic
    requested = set(FAMILIES) if families == "auto" else {families} if isinstance(families,str) else set(families)
    if not requested or not all(isinstance(name,str) for name in requested):
        raise EvidenceError("INVALID_QUERY", "Recognition families must be names or auto")
    if type(triangle_budget) is not int or not 1 <= triangle_budget <= 1000000:
        raise EvidenceError("INVALID_QUERY", "recognition_triangle_budget must be from 1 to 1000000")
    diagnostics = [diagnostic("UNSUPPORTED_RECOGNITION_FAMILY", f"No regional recognizer for {name}") for name in sorted(requested-FAMILIES)]
    requested &= FAMILIES
    identity = np.eye(3)
    eligible, clipped, degenerate = [], [], []
    for tid, polygons in sorted(selection.items()):
        if analysis["areas"][tid]<=0:
            degenerate.append(tid)
            continue
        complete = len(polygons)==1 and np.asarray(polygons[0]).shape==(3,3) and np.array_equal(np.asarray(polygons[0]),identity)
        (eligible if complete else clipped).append(tid)
    selected = eligible[:triangle_budget]
    unknown = set(clipped) | set(degenerate) | set(eligible[triangle_budget:])
    if degenerate:
        diagnostics.append(diagnostic("DEGENERATE_RECOGNITION_SCOPE", "Zero-area source triangles remain unresolved and are not used to fit regional surfaces", triangle_ids=degenerate))
    if clipped:
        diagnostics.append(diagnostic("CLIPPED_RECOGNITION_SCOPE", "Regional recognition leaves clipped triangle portions unresolved; select complete original triangles to recognize them", triangle_ids=clipped))
    if len(eligible)>triangle_budget:
        diagnostics.append(diagnostic("BUDGET_EXHAUSTED", "Regional recognition reached its triangle work budget; untouched source remains unknown", processed_triangles=len(selected), unprocessed_triangles=len(eligible)-len(selected)))
    if not selected or not requested:
        return {"recognition_records":[], "recognized_regions":[], "recognition_unknown_triangle_ids":sorted(set(selection)), "recognition_diagnostics":diagnostics,
                "recognition_work":{"processed_triangle_count":0,"triangle_budget":triangle_budget,"algorithm_version":VERSION}}
    tids=np.asarray(selected,int); faces=analysis["faces"][tids]
    points,inverse=np.unique(faces.reshape(-1,3),axis=0,return_inverse=True)
    triangles=inverse.reshape(-1,3);normals=analysis["normals"][tids];areas=analysis["areas"][tids]
    mapping={tid:index for index,tid in enumerate(selected)}
    adjacency=[{mapping[neighbor] for neighbor in analysis["adjacency"][tid] if neighbor in mapping} for tid in selected]
    scale=analysis["scale"]
    axes=_axes(points,normals,areas)
    regions,_lookup=_coherent_regions(points,triangles,normals,areas,adjacency,axes,scale)
    center=(points.min(axis=0)+points.max(axis=0))/2
    hints=[{"id":"axis-hint-"+str(i),"axis_hint":axis.tolist(),"axis_origin":center.tolist(),"surface_kind":"frame_hint","triangle_ids":[],"area":0.} for i,axis in enumerate(axes)]
    if "torus" in requested:
        regions=refine_torus_regions(points,triangles,normals,areas,adjacency,regions+hints,scale)
        regions=[region for region in regions if region["surface_kind"]!="frame_hint"]
        if not any(region["surface_kind"]=="torus" for region in regions):
            # A regular torus grid can consist entirely of planar quad pairs.
            # Treat their union as an alternative search scope, not evidence
            # that each facet is an intentional planar design feature.
            pooled={"id":"pooled-torus-search","surface_kind":"unresolved_curved","triangle_ids":list(range(len(triangles))),"area":float(areas.sum()),"bounds":{"min":points.min(axis=0).tolist(),"max":points.max(axis=0).tolist()}}
            found=refine_torus_regions(points,triangles,normals,areas,adjacency,[pooled],scale,frame_regions=regions+hints)
            tori=[region for region in found if region["surface_kind"]=="torus"]
            covered={tid for region in tori for tid in region["triangle_ids"]}
            if covered:
                remaining=[]
                for region in regions:
                    for group in connected_components(set(region["triangle_ids"])-covered,adjacency):
                        item=copy.deepcopy(region);values=points[triangles[group]].reshape(-1,3)
                        item.update(id="region-"+canonical_digest(group)[:20],triangle_ids=group,area=float(areas[group].sum()),bounds={"min":values.min(axis=0).tolist(),"max":values.max(axis=0).tolist()})
                        remaining.append(item)
                regions=remaining+tori
    helices=helical_profile_evidence(points,triangles,normals,regions+hints,scale) if "helical_sweep" in requested else []
    rounded=rounded_extrusion_evidence(points,triangles,regions+hints,scale) if "rounded_rectangle_extrusion" in requested else []
    records=[]
    def add(family,geometry,local_ids,error,**details):
        local_ids=sorted(set(int(i) for i in local_ids))
        if not local_ids:return
        original=[selected[i] for i in local_ids];values=faces[local_ids].reshape(-1,3)
        bounds={"min":values.min(axis=0).tolist(),"max":values.max(axis=0).tolist()}
        record={"family":family,"geometry":geometry,"triangle_ids":original,"bounds":bounds,
                "area":float(areas[local_ids].sum()),"fit_report":{"source_vertex_maximum":float(error),"guarantee":"sampled_local_fit_only","final_acceptance":"not_evaluated"},
                "observed_extent":{"bounds":bounds,"triangle_ids":original,"classification":"observed_surface_support_only","terminal_faces_observed":False},
                "material_role":"unknown","unresolved_decisions":["material_side","finite_construction_extent","unobserved_trims_and_neighboring_features"],**details}
        record["id"]="recognition-"+canonical_digest([context["source_hash"],record])[:24]
        records.append(record)
        return record
    for region in regions:
        family=region["surface_kind"]
        if family not in requested or family not in {"plane","sphere","cylinder","torus"}:continue
        geometry=copy.deepcopy(region.get("analytic_model"))
        if family=="plane":
            normal=np.asarray(region["plane"]["normal"]);x,_y,_axis=_frame(normal)
            geometry={"kind":"plane","normal":normal.tolist(),"origin":(normal*region["plane"]["offset"]).tolist(),"x_direction":x.tolist()}
        if not geometry:continue
        error=region.get("fit_error",{}).get("source_vertex_maximum",0.)
        if family=="plane":
            values=faces[region["triangle_ids"]]
            error=float(np.abs((values-geometry["origin"])@np.asarray(geometry["normal"])).max())
        if family=="cylinder":
            height=geometry.pop("height");interval=[0.,height]
            record=add(family,geometry,region["triangle_ids"],error,orientation_agreement=region.get("orientation_agreement"))
            if record:record["observed_extent"]["axial_interval"]=interval
        else:
            record=add(family,geometry,region["triangle_ids"],error,orientation_agreement=region.get("orientation_agreement"))
            if record and family=="plane":record["fit_report"]["triangle_centroid_maximum"]=float(np.abs((values.mean(axis=1)-geometry["origin"])@np.asarray(geometry["normal"])).max())
    for feature in helices:
        geometry=copy.deepcopy(feature["model"]);height=geometry.pop("height")
        geometry["profile"]={"origin":[0,0,0],"normal":[0,0,1],"x_direction":[1,0,0],"loops":[{"closed":True,"points":geometry["profile"]["outer"]}]}
        owned=[tid for flank in feature["flanks"] for tid in flank["triangle_ids"]]
        record=add("helical_sweep",geometry,owned,feature["fit_error"]["source_vertex_maximum"],radial_range=feature["radial_range"])
        if record:
            record["observed_extent"]["axial_interval"]=[0.,height]
            record["unresolved_decisions"].append("profile_closure_between_observed_flanks")
    for feature in rounded:
        axis=np.asarray(feature["axis"]);low,high=feature["observed_axial_interval"]
        profile={"origin":(axis*low).tolist(),"normal":axis.tolist(),"x_direction":feature["x_direction"],"loops":[{"closed":True,"role":"outer","segments":feature["profile"]["outer"]["segments"]}]}
        owned=feature.get("parallel_side_triangle_ids")
        if owned is None:
            source_ids={tid for region in regions if region["id"] in feature["region_ids"] for tid in region["triangle_ids"]}
            x=np.asarray(feature["x_direction"]);y=np.cross(axis,x);d=feature["dimensions"];angle=d["angle_radians"]
            rotation=np.array([[math.cos(angle),-math.sin(angle)],[math.sin(angle),math.cos(angle)]])
            q=np.abs((np.stack((points[triangles]@x,points[triangles]@y),axis=-1).reshape(-1,2)-d["center"])@rotation)-np.array([d["width"]/2-d["corner_radius"],d["height"]/2-d["corner_radius"]])
            residual=(np.linalg.norm(np.maximum(q,0),axis=1)+np.minimum(np.maximum(q[:,0],q[:,1]),0)-d["corner_radius"]).reshape(-1,3)
            owned=[tid for tid in source_ids if abs(float(normals[tid]@axis))<.003 and np.max(np.abs(residual[tid]))<=scale*3e-5]
        geometry={"kind":"rounded_rectangle_extrusion","profile":profile,"direction":axis.tolist(),"observed_interval":[0.,high-low],"dimensions":feature["dimensions"]}
        error=max(feature["fit_error"].get("source_profile_maximum",0.),feature["fit_error"].get("section_maximum",0.))
        record=add("rounded_rectangle_extrusion",geometry,owned,error)
        if record:record["observed_extent"]["axial_interval"]=[0.,high-low]
    if "concentric_spherical_shell" in requested:
        spheres=[region for region in regions if region["surface_kind"]=="sphere"]
        for outer in spheres:
            for inner in spheres:
                a,b=outer["analytic_model"],inner["analytic_model"]
                if outer.get("orientation_agreement",0)<=0 or inner.get("orientation_agreement",0)>=0 or a["radius"]<=b["radius"]:continue
                if np.linalg.norm(np.asarray(a["center"])-b["center"])>scale*1e-5:continue
                common=(np.asarray(a["center"])+b["center"])/2;owned=outer["triangle_ids"]+inner["triangle_ids"]
                error=max(float(np.abs(np.linalg.norm(points[triangles[region["triangle_ids"]]]-common,axis=2)-model["radius"]).max()) for region,model in ((outer,a),(inner,b)))
                add("concentric_spherical_shell",{"kind":"concentric_spherical_shell","center":common.tolist(),"outer_radius":a["radius"],"inner_radius":b["radius"]},owned,error,
                    surface_members=[{"role":"outer","triangle_ids":[selected[i] for i in outer["triangle_ids"]]},{"role":"inner","triangle_ids":[selected[i] for i in inner["triangle_ids"]]}])
    # Recompute IDs after support extents were added; record files and handles
    # remain content addressed and independent of the current CAD revision.
    for record in records:record["id"]="recognition-"+canonical_digest([context["source_hash"],{k:v for k,v in record.items() if k!="id"}])[:24]
    records.sort(key=lambda record:(-record["area"],record["family"],record["id"]))
    covered={tid for record in records for tid in record["triangle_ids"]}
    unknown.update(set(selected)-covered)
    summaries=[]
    for region in regions:
        original=[selected[i] for i in region["triangle_ids"]]
        summaries.append({"id":"recognized-region-"+canonical_digest([context["source_hash"],original])[:24],"triangle_ids":original,"surface_kind":region["surface_kind"],"area":region["area"],"bounds":region["bounds"],"provisional":True})
    if unknown:diagnostics.append(diagnostic("UNRESOLVED_RECOGNITION_SCOPE","Requested recognizers leave source triangles without a geometric explanation",triangle_count=len(unknown)))
    return {"recognition_records":records,"recognized_regions":summaries,"recognition_unknown_triangle_ids":sorted(unknown),"recognition_diagnostics":diagnostics,
            "recognition_work":{"processed_triangle_count":len(selected),"triangle_budget":triangle_budget,"algorithm_version":VERSION,"bounded_sphere_passes":4,"sphere_trials_per_pass":320}}
