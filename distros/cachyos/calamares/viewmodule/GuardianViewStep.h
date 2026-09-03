/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef GUARDIANVIEWSTEP_H
#define GUARDIANVIEWSTEP_H

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>

class GuardianPage;

class PLUGINDLLEXPORT GuardianViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit GuardianViewStep( QObject* parent = nullptr );
    ~GuardianViewStep() override;

    QString prettyName() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;

    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    void onLeave() override;
    Calamares::JobList jobs() const override;

    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    GuardianPage* m_widget = nullptr;
    QVariantMap m_configurationMap;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( GuardianViewStepFactory )

#endif  // GUARDIANVIEWSTEP_H
