import AppKit
import ApplicationServices

func axCopyCGRectAttribute(_ element: AXUIElement, attribute: CFString) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else {
        return nil
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let ax = value as! AXValue
    var rect = CGRect.zero
    guard AXValueGetValue(ax, .cgRect, &rect) else {
        return nil
    }
    return rect
}

func axElementFrame(_ element: AXUIElement) -> CGRect? {
    axCopyCGRectAttribute(element, attribute: "AXFrame" as CFString)
}

/// Computes the tight module rect by unioning the content children of the AXGroup inside AXFocusedWindow.
///
/// The CC layer-101 window always has the structure:
///   AXWindow (510x1357 backing)
///     └─ AXGroup (510x1357 backing)
///          ├─ title/icon/slider/...   ← actual module content
///          └─ "Module Settings…" button
///
/// The bounding rect of the AXGroup's children is the real module content area.
func axChildrenUnionRectForCCModule(
    app: AXUIElement,
    layer101Bounds: CGRect,
    screenFrame: CGRect
) -> CGRect? {
    var ref: CFTypeRef?
    let window: AXUIElement
    if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &ref) == .success, let r = ref {
        window = r as! AXUIElement
    } else if AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &ref) == .success, let r = ref {
        window = r as! AXUIElement
    } else {
        return nil
    }

    var childRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXChildren" as CFString, &childRef) == .success,
          let windowChildren = childRef as? [AXUIElement],
          let group = windowChildren.first else { return nil }

    var groupChildRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(group, "AXChildren" as CFString, &groupChildRef) == .success,
          let groupChildren = groupChildRef as? [AXUIElement],
          !groupChildren.isEmpty else { return nil }

    var union = CGRect.null
    for child in groupChildren {
        guard let frame = axElementFrame(child) else { continue }
        union = union.isNull ? frame : union.union(frame)
    }
    guard !union.isNull, union.width >= 60, union.height >= 4 else { return nil }

    let leftPad: CGFloat = 16
    let bPad: CGFloat = 20
    let panel = CGRect(
        x: union.minX - leftPad,
        y: layer101Bounds.minY,
        width: max(union.width + leftPad, 320),
        height: union.maxY - layer101Bounds.minY + bPad
    ).intersection(screenFrame)

    guard !panel.isNull,
          panel.width >= 60, panel.height >= 40,
          panel.height < layer101Bounds.height * 0.80 else { return nil }

    return panel
}
