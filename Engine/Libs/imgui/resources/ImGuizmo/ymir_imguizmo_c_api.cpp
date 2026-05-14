#include "imgui.h"
#include "ImGuizmo.h"

extern "C" {

void ImGuizmo_SetOrthographic(bool orthographic) {
    ImGuizmo::SetOrthographic(orthographic);
}

void ImGuizmo_SetDrawlist(void* drawlist) {
    if (drawlist != nullptr) {
        ImGuizmo::SetDrawlist(static_cast<ImDrawList*>(drawlist));
    } else {
        ImGuizmo::SetDrawlist();
    }
}

void ImGuizmo_SetImGuiContext(void* ctx) {
    ImGuizmo::SetImGuiContext(static_cast<ImGuiContext*>(ctx));
}

void ImGuizmo_BeginFrame() {
    ImGuizmo::BeginFrame();
}

void ImGuizmo_SetRect(float x, float y, float width, float height) {
    ImGuizmo::SetRect(x, y, width, height);
}

bool ImGuizmo_Manipulate(
    const float* view,
    const float* projection,
    int operation,
    int mode,
    float* matrix,
    float* deltaMatrix,
    const float* snap,
    const float* localBounds,
    const float* boundsSnap
) {
    return ImGuizmo::Manipulate(
        view,
        projection,
        static_cast<ImGuizmo::OPERATION>(operation),
        static_cast<ImGuizmo::MODE>(mode),
        matrix,
        deltaMatrix,
        snap,
        localBounds,
        boundsSnap
    );
}

void ImGuizmo_DecomposeMatrixToComponents(
    const float* matrix,
    float* translation,
    float* rotation,
    float* scale
) {
    ImGuizmo::DecomposeMatrixToComponents(matrix, translation, rotation, scale);
}

void ImGuizmo_RecomposeMatrixFromComponents(
    const float* translation,
    const float* rotation,
    const float* scale,
    float* matrix
) {
    ImGuizmo::RecomposeMatrixFromComponents(translation, rotation, scale, matrix);
}

bool ImGuizmo_IsOver() {
    return ImGuizmo::IsOver();
}

bool ImGuizmo_IsUsing() {
    return ImGuizmo::IsUsing();
}

}
