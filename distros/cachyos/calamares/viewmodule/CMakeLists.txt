# SPDX-FileCopyrightText: 2026 Parental-OS
# SPDX-License-Identifier: GPL-3.0-or-later

cmake_minimum_required(VERSION 3.20)
project(calamares_viewmodule_guardian LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
find_package(KF6CoreAddons REQUIRED)
find_package(Calamares REQUIRED)

calamares_add_plugin(guardian
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        GuardianPage.h
        GuardianPage.cpp
        GuardianJob.h
        GuardianJob.cpp
        GuardianViewStep.h
        GuardianViewStep.cpp
    SHARED_LIB
    LINK_LIBRARIES
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
        Calamares::calamares
        Calamares::calamaresui
)
