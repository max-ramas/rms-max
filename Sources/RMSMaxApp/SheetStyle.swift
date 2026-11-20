// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI

extension View {
    /// Consistent modal sheets on macOS: grouped form layout (no truncated label column) and a sane minimum size.
    func macSheet(width: CGFloat = 460, height: CGFloat = 360) -> some View {
        #if os(macOS)
        return self.formStyle(.grouped).frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        return self.formStyle(.grouped)
        #endif
    }
}
