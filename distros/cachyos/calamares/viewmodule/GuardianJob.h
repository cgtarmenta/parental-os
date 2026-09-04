/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef GUARDIANJOB_H
#define GUARDIANJOB_H

#include "CppJob.h"
#include <QString>

class GuardianJob : public Calamares::CppJob
{
    Q_OBJECT

public:
    explicit GuardianJob( const QString& hash = QString(), QObject* parent = nullptr );
    ~GuardianJob() override = default;

    QString prettyName() const override;
    Calamares::JobResult exec() override;

private:
    QString m_hash;
};

#endif  // GUARDIANJOB_H
