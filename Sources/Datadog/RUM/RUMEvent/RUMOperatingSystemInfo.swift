/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

extension RUMOperatingSystem {
    init(from device: MobileDevice) {
        self.name = device.osName
        self.version = device.osVersion
        self.versionMajor = device.osVersion.split(separator: ".").first.map { String($0) } ?? device.osVersion
    }
}
