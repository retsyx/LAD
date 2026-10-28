import AppKit
import Metal
import SceneKit

/// Visibility is resolved on thin native centerlines and vertex centers.
/// Screen-space distance expansion gives highlights stable widths and circles
/// without letting adjacent sloping surfaces clip their expanded footprints.
@MainActor
enum CADHighlightTechnique {
    static let hiddenEdgeCategory = 16
    static let seedCategory = 32
    static let completionCategory = 64
    static let completionNodeName = "ladHighlightFrameCompleted"
    private static let heightKey = "cadReferenceHeight"
    private static let verticesKey = "cadVertexHighlightsEnabled"
    private static let translucentKey = "cadTranslucentFaces"
    private static let colorKeys = ["cadSelectedColor", "cadHoverColor", "cadHoverHaloColor", "cadInkColor"]
    private static var cachedLibrary: (device: UInt64, library: any MTLLibrary)?

    static func make(viewportHeight: CGFloat, selected: NSColor, hover: NSColor,
                     hoverHalo: NSColor, ink: NSColor, frameCompletion: Bool = false,
                     vertexHighlights: Bool = true, translucentFaces: Bool = false) -> SCNTechnique? {
        guard let device = MTLCreateSystemDefaultDevice(), let library = library(for: device),
              let technique = SCNTechnique(dictionary: definition(frameCompletion: frameCompletion,
                                                                 translucentFaces: translucentFaces)) else { return nil }
        technique.library = library
        setViewportHeight(viewportHeight, on: technique)
        setVertexHighlightsEnabled(vertexHighlights, on: technique)
        technique.setValue(NSNumber(value: translucentFaces ? 1.0 : 0.0), forKey: translucentKey)
        for (key, color) in zip(colorKeys, [selected, hover, hoverHalo, ink]) {
            technique.setValue(linearColor(color), forKey: key)
        }
        return technique
    }

    static func setViewportHeight(_ height: CGFloat, on technique: SCNTechnique) {
        let value = Double(height.isFinite ? max(1, height) : 1)
        if let current = technique.value(forKey: heightKey) as? NSNumber, current.doubleValue == value { return }
        technique.setValue(NSNumber(value: value), forKey: heightKey)
    }

    /// Keep the smaller edge-only search radius during ordinary navigation.
    /// Changing this scalar reuses the prepared geometry and render targets.
    static func setVertexHighlightsEnabled(_ enabled: Bool, on technique: SCNTechnique) {
        let value = enabled ? 1.0 : 0.0
        if let current = technique.value(forKey: verticesKey) as? NSNumber, current.doubleValue == value { return }
        technique.setValue(NSNumber(value: value), forKey: verticesKey)
    }

    /// Reconstruct targets for the independent renderer rather than sharing
    /// mutable per-view render attachments with the live viewport.
    static func copy(_ source: SCNTechnique) -> SCNTechnique? {
        guard let technique = SCNTechnique(dictionary: source.dictionaryRepresentation) else { return nil }
        technique.library = source.library
        for key in [heightKey, verticesKey, translucentKey] + colorKeys {
            if let value = source.value(forKey: key) { technique.setValue(value, forKey: key) }
        }
        return technique
    }

    private static func library(for device: any MTLDevice) -> (any MTLLibrary)? {
        if let cachedLibrary, cachedLibrary.device == device.registryID { return cachedLibrary.library }
        guard let library = try? device.makeLibrary(source: librarySource, options: nil) else { return nil }
        cachedLibrary = (device.registryID, library)
        return library
    }

    private static func linearColor(_ color: NSColor) -> NSValue {
        let color = color.usingColorSpace(.extendedSRGB) ?? color
        func linear(_ component: CGFloat) -> Float {
            let value = Double(component)
            return Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        return NSValue(scnVector4: SCNVector4(linear(color.redComponent), linear(color.greenComponent),
                                             linear(color.blueComponent), Float(color.alphaComponent)))
    }

    private static func definition(frameCompletion: Bool, translucentFaces: Bool) -> [String: Any] {
        var symbols: [String: Any] = [heightKey: ["type": "float"], verticesKey: ["type": "float"], translucentKey: ["type": "float"]]
        for key in colorKeys { symbols[key] = ["type": "vec4"] }
        let nearest: (String) -> [String: Any] = { ["target": $0, "minificationFilter": "nearest", "magnificationFilter": "nearest"] }
        var compositeInputs: [String: Any] = ["cadDistances": nearest(translucentFaces ? "cadRevealage" : "cadHorizontalDistances"),
                                              "cadSceneColor": nearest(translucentFaces ? "cadAccumulatedColor" : "cadSceneColor"), heightKey: heightKey,
                                              verticesKey: verticesKey, translucentKey: translucentKey]
        compositeInputs["cadHighlightDistances"] = nearest("cadHorizontalDistances")
        compositeInputs["cadDecorationsColor"] = nearest("cadSceneColor")
        compositeInputs["cadBackgroundColor"] = nearest(translucentFaces ? "cadBackgroundColor" : "cadSceneColor")
        for key in colorKeys { compositeInputs[key] = key }
        return [
            "sequence": (translucentFaces ? ["cadBackground", "cadVisibility", "cadAccumulate", "cadReveal"] : ["cadBase"])
                + ["cadDecorations", "cadSeeds", "cadHorizontal", "cadComposite"] + (frameCompletion ? ["cadCompleted"] : []),
            "symbols": symbols,
            "targets": [
                "cadSceneColor": ["type": "color"],
                "cadVisibilityColor": ["type": "color"],
                "cadAccumulatedColor": ["type": "color", "format": "rgba16f"],
                "cadRevealage": ["type": "color", "format": "rgba16f"],
                "cadBackgroundColor": ["type": "color"],
                "cadSceneDepth": ["type": "depth", "format": "depth32f"],
                "cadSeedMask": ["type": "color", "format": "rgba8"],
                "cadHorizontalDistances": ["type": "color", "format": "rgba16f"]
            ],
            "passes": [
                // Only solid faces own visibility depth. Technique-level
                // depth states override material writesToDepthBuffer, so a
                // single mixed pass would let expanded ink occlude its seeds.
                "cadBase": ["draw": "DRAW_SCENE", "includeCategoryMask": 1, "cullMode": "none",
                    "outputs": ["color": "cadSceneColor", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": true, "clearColor": "sceneBackground"],
                    "depthStates": ["clear": true, "enableRead": true, "enableWrite": true]],
                "cadBackground": ["draw": "DRAW_SCENE", "includeCategoryMask": 0, "samples": 4,
                    "outputs": ["color": "cadBackgroundColor"],
                    "colorStates": ["clear": true, "clearColor": "sceneBackground"],
                    "depthStates": ["clear": false, "enableRead": false, "enableWrite": false]],
                // Nearest solid depth belongs only to decorations/highlights;
                // it must never reject a transparent color contribution.
                "cadVisibility": ["draw": "DRAW_SCENE", "includeCategoryMask": 1, "cullMode": "none",
                    "outputs": ["color": "cadVisibilityColor", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": true, "clearColor": "0 0 0 0"],
                    "depthStates": ["clear": true, "enableRead": true, "enableWrite": true]],
                // Both operations are commutative. Native PBR shading produces
                // premultiplied RGBA, so equal weights accumulate color/alpha
                // without requiring a second shader or per-frame geometry sort.
                "cadAccumulate": ["draw": "DRAW_SCENE", "includeCategoryMask": 1, "cullMode": "none",
                    "outputs": ["color": "cadAccumulatedColor", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": true, "clearColor": "0 0 0 0"],
                    "depthStates": ["clear": false, "enableRead": false, "enableWrite": false],
                    "blendStates": ["enable": true, "colorSrc": "one", "colorDst": "one", "colorOp": "add",
                                    "alphaSrc": "one", "alphaDst": "one", "alphaOp": "add"]],
                "cadReveal": ["draw": "DRAW_SCENE", "includeCategoryMask": 1, "cullMode": "none",
                    "outputs": ["color": "cadRevealage", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": true, "clearColor": "1 1 1 1"],
                    "depthStates": ["clear": false, "enableRead": false, "enableWrite": false],
                    "blendStates": ["enable": true, "colorSrc": "zero", "colorDst": "oneMinusSrcAlpha", "colorOp": "add",
                                    "alphaSrc": "zero", "alphaDst": "oneMinusSrcAlpha", "alphaOp": "add"]],
                "cadDecorations": ["draw": "DRAW_SCENE", "includeCategoryMask": 2 | 4, "cullMode": "none",
                    "outputs": ["color": "cadSceneColor", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": translucentFaces, "clearColor": "0 0 0 0"],
                    "depthStates": ["clear": false, "enableRead": true, "enableWrite": false]],
                "cadSeeds": ["draw": "DRAW_SCENE", "includeCategoryMask": seedCategory, "cullMode": "none",
                    "outputs": ["color": "cadSeedMask", "depth": "cadSceneDepth"], "samples": 4,
                    "colorStates": ["clear": true, "clearColor": "0 0 0 0"],
                    "depthStates": ["clear": false, "enableRead": true, "enableWrite": false],
                    "blendStates": ["enable": true, "colorSrc": "one", "colorDst": "one", "colorOp": "max",
                                    "alphaSrc": "one", "alphaDst": "one", "alphaOp": "max"]],
                "cadHorizontal": ["draw": "DRAW_QUAD", "samples": 1,
                    "metalVertexShader": "cad_highlight_quad", "metalFragmentShader": "cad_highlight_horizontal",
                    "inputs": ["cadSeeds": nearest("cadSeedMask"), heightKey: heightKey, verticesKey: verticesKey],
                    "outputs": ["color": "cadHorizontalDistances"],
                    "depthStates": ["enableRead": false, "enableWrite": false], "blendStates": ["enable": false]],
                "cadComposite": ["draw": "DRAW_QUAD", "samples": 1,
                    "metalVertexShader": "cad_highlight_quad", "metalFragmentShader": "cad_highlight_composite",
                    "inputs": compositeInputs, "outputs": ["color": "COLOR"],
                    "depthStates": ["enableRead": false, "enableWrite": false], "blendStates": ["enable": false]],
                // SceneKit omits ordinary scene-completion delegates for some
                // technique frames. A geometry-free final node acknowledges
                // the complete frame after the highlight has been composited.
                "cadCompleted": ["draw": "DRAW_NODE", "node": completionNodeName, "samples": 1,
                    "includeCategoryMask": completionCategory,
                    "outputs": ["color": "COLOR"], "colorStates": ["clear": false],
                    "depthStates": ["enableRead": false, "enableWrite": false]]
            ]
        ]
    }

    // Do not include SceneKit/scn_metal here: that SDK-only header is absent
    // from the runtime framework. Fullscreen passes need only position (0).
    private static let librarySource = """
    #include <metal_stdlib>
    using namespace metal;
    struct CADQuadInput { float3 position [[attribute(0)]]; };
    struct CADQuadOutput { float4 position [[position]]; };
    struct CADHighlightParameters {
        float cadReferenceHeight;
        float cadVertexHighlightsEnabled;
        float cadTranslucentFaces;
        float4 cadSelectedColor;
        float4 cadHoverColor;
        float4 cadHoverHaloColor;
        float4 cadInkColor;
    };
    // Share the logical diameters with fallback geometry rather than letting
    // independently copied shader constants drift from the live marker style.
    constant float cadVertexHoverRadius = \(Float(CADVertexGeometry.hoverDiameter / 2))f;
    constant float cadVertexSelectedRadius = \(Float(CADVertexGeometry.selectedDiameter / 2))f;
    constant float cadVertexHoverHaloRadius = \(Float(CADVertexGeometry.hoverHaloDiameter / 2))f;
    constant float cadVertexSelectedHaloRadius = \(Float(CADVertexGeometry.selectedHaloDiameter / 2))f;
    constant float cadMaximumRadius = \(Float(max(2.75, max(CADVertexGeometry.hoverHaloDiameter, CADVertexGeometry.selectedHaloDiameter) / 2)))f;
    // Bound the kernel while retaining complete circles at the largest
    // supported independent-capture scale (8×), including antialias coverage.
    constant int cadMaximumKernelRadius = \(Int(ceil(Double(max(2.75, max(CADVertexGeometry.hoverHaloDiameter, CADVertexGeometry.selectedHaloDiameter) / 2)) * 8 + 0.5)));
    vertex CADQuadOutput cad_highlight_quad(CADQuadInput in [[stage_in]]) {
        CADQuadOutput out;
        out.position = float4(in.position, 1.0);
        return out;
    }
    fragment float4 cad_highlight_horizontal(
        CADQuadOutput in [[stage_in]],
        texture2d<float, access::read> cadSeeds [[texture(0)]],
        constant CADHighlightParameters &params [[buffer(0)]]) {
        int2 size = int2(cadSeeds.get_width(), cadSeeds.get_height());
        int2 center = int2(in.position.xy);
        float scale = clamp(float(size.y) / max(params.cadReferenceHeight, 1.0f), 0.125f, 8.0f);
        bool verticesEnabled = params.cadVertexHighlightsEnabled > 0.5f;
        float maximumRadius = verticesEnabled ? cadMaximumRadius : 2.75f;
        int radius = min(min(size.x - 1, cadMaximumKernelRadius), int(ceil(maximumRadius * scale + 0.5f)));
        float4 best = float4(65504.0f);
        int first = max(-radius, -center.x);
        int last = min(radius, size.x - 1 - center.x);
        for (int dx = first; dx <= last; ++dx) {
            // RG are selected/hover edges; BA are selected/hover vertices.
            float4 seeds = cadSeeds.read(uint2(center + int2(dx, 0)));
            float distance = float(dx) * float(dx);
            if (seeds.r > 0.01f) { best.r = min(best.r, distance); }
            if (seeds.g > 0.01f) { best.g = min(best.g, distance); }
            if (verticesEnabled) {
                if (seeds.b > 0.01f) { best.b = min(best.b, distance); }
                if (seeds.a > 0.01f) { best.a = min(best.a, distance); }
            }
        }
        return best;
    }
    fragment float4 cad_highlight_composite(
        CADQuadOutput in [[stage_in]],
        texture2d<float, access::read> cadDistances [[texture(0)]],
        texture2d<float, access::read> cadSceneColor [[texture(1)]],
        texture2d<float, access::read> cadHighlightDistances [[texture(2)]],
        texture2d<float, access::read> cadDecorationsColor [[texture(3)]],
        texture2d<float, access::read> cadBackgroundColor [[texture(4)]],
        constant CADHighlightParameters &params [[buffer(0)]]) {
        bool translucent = params.cadTranslucentFaces > 0.5f;
        int2 size = int2(cadDistances.get_width(), cadDistances.get_height());
        int2 center = int2(in.position.xy);
        float scale = clamp(float(size.y) / max(params.cadReferenceHeight, 1.0f), 0.125f, 8.0f);
        bool verticesEnabled = params.cadVertexHighlightsEnabled > 0.5f;
        float maximumRadius = verticesEnabled ? cadMaximumRadius : 2.75f;
        int radius = min(min(size.y - 1, cadMaximumKernelRadius), int(ceil(maximumRadius * scale + 0.5f)));
        float4 best = float4(65504.0f);
        int first = max(-radius, -center.y);
        int last = min(radius, size.y - 1 - center.y);
        for (int dy = first; dy <= last; ++dy) {
            float4 horizontal = translucent ? cadHighlightDistances.read(uint2(center + int2(0, dy)))
                : cadDistances.read(uint2(center + int2(0, dy)));
            best = min(best, horizontal + float(dy) * float(dy));
        }
        float4 distance = sqrt(best);
        float4 result = cadSceneColor.read(uint2(center));
        if (translucent) {
            float revealage = saturate(cadDistances.read(uint2(center)).a);
            float4 background = cadBackgroundColor.read(uint2(center));
            float coverage = 1.0f - revealage;
            float3 averageColor = result.rgb / max(result.a, 1.0e-5f);
            result = float4(averageColor * coverage + background.rgb * revealage,
                            coverage + background.a * revealage);
            float4 decorations = cadDecorationsColor.read(uint2(center));
            result = decorations + result * (1.0f - saturate(decorations.a));
        }
        // A one-pixel transition preserves the same logical widths on Retina
        // and independent agent captures, without changing the seed geometry.
        float hoverHalo = saturate(2.5f * scale + 0.5f - distance.g);
        float hoverCore = saturate(1.5f * scale + 0.5f - distance.g);
        float selectedHalo = saturate(2.75f * scale + 0.5f - distance.r);
        float selectedCore = saturate(2.0f * scale + 0.5f - distance.r);
        float vertexHoverHalo = saturate(cadVertexHoverHaloRadius * scale + 0.5f - distance.a);
        float vertexHoverCore = saturate(cadVertexHoverRadius * scale + 0.5f - distance.a);
        float vertexSelectedHalo = saturate(cadVertexSelectedHaloRadius * scale + 0.5f - distance.b);
        float vertexSelectedCore = saturate(cadVertexSelectedRadius * scale + 0.5f - distance.b);
        result = mix(result, params.cadHoverHaloColor, hoverHalo * params.cadHoverHaloColor.a);
        result = mix(result, params.cadHoverColor, hoverCore * params.cadHoverColor.a);
        if (verticesEnabled) {
            result = mix(result, params.cadHoverHaloColor, vertexHoverHalo * params.cadHoverHaloColor.a);
            result = mix(result, params.cadHoverColor, vertexHoverCore * params.cadHoverColor.a);
        }
        // Every selected feature wins over every hovered feature; vertices
        // stay legible where they coincide with a selected edge endpoint.
        result = mix(result, params.cadInkColor, selectedHalo * params.cadInkColor.a);
        result = mix(result, params.cadSelectedColor, selectedCore * params.cadSelectedColor.a);
        if (verticesEnabled) {
            result = mix(result, params.cadInkColor, vertexSelectedHalo * params.cadInkColor.a);
            result = mix(result, params.cadSelectedColor, vertexSelectedCore * params.cadSelectedColor.a);
        }
        return result;
    }
    """
}
