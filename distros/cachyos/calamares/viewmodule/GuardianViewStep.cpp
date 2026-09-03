/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "GuardianViewStep.h"
#include "GuardianJob.h"
#include "GuardianPage.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "utils/Logger.h"

CALAMARES_PLUGIN_FACTORY_DEFINITION( GuardianViewStepFactory, registerPlugin< GuardianViewStep >(); )

GuardianViewStep::GuardianViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_widget( new GuardianPage() )
{
    connect( m_widget, &GuardianPage::checkValidity, this, [this]() {
        emit nextStatusChanged( isNextEnabled() );
    } );

    emit nextStatusChanged( isNextEnabled() );
}

GuardianViewStep::~GuardianViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString GuardianViewStep::prettyName() const
{
    return tr( "Parental Guard", "@title" );
}

QWidget* GuardianViewStep::widget()
{
    return m_widget;
}

bool GuardianViewStep::isNextEnabled() const
{
    return m_widget && m_widget->isValid();
}

bool GuardianViewStep::isBackEnabled() const
{
    return true;
}

bool GuardianViewStep::isAtBeginning() const
{
    return true;
}

bool GuardianViewStep::isAtEnd() const
{
    return true;
}

void GuardianViewStep::onLeave()
{
    if ( !m_widget )
    {
        return;
    }

    const QString hash = m_widget->computedHash();
    cDebug() << "GuardianViewStep: leaving step, computed hash is set";

    Calamares::GlobalStorage* gs = Calamares::JobQueue::instance()->globalStorage();
    if ( gs )
    {
        gs->insert( QStringLiteral( "guardianHash" ), hash );
    }
}

Calamares::JobList GuardianViewStep::jobs() const
{
    Calamares::JobList l;
    QString hash;
    if ( m_widget )
    {
        hash = m_widget->computedHash();
    }
    l.append( Calamares::job_ptr( new GuardianJob( hash ) ) );
    return l;
}

void GuardianViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_configurationMap = configurationMap;
}
