/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "GuardianJob.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "utils/Logger.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <sys/stat.h>
#include <unistd.h>

GuardianJob::GuardianJob( const QString& hash, QObject* parent )
    : Calamares::CppJob( parent )
    , m_hash( hash )
{
}

QString GuardianJob::prettyName() const
{
    return tr( "Configuring Parental Guard secret…", "@status" );
}

static bool writeSecureFile( const QString& filePath, const QString& content )
{
    QFileInfo fi( filePath );
    QDir().mkpath( fi.absolutePath() );

    QFile file( filePath );
    if ( !file.open( QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text ) )
    {
        cError() << "GuardianJob: unable to open" << filePath << "for writing:" << file.errorString();
        return false;
    }

    file.write( ( content.trimmed() + QStringLiteral( "\n" ) ).toUtf8() );
    file.close();

    const QByteArray localPath = QFile::encodeName( filePath );
    if ( chmod( localPath.constData(), 0600 ) != 0 )
    {
        cWarning() << "GuardianJob: unable to chmod 0600" << filePath;
    }

    if ( chown( localPath.constData(), 0, 0 ) != 0 )
    {
        // May fail harmlessly if not running as root in certain environments
        cDebug() << "GuardianJob: chown 0:0 on" << filePath;
    }

    return true;
}

Calamares::JobResult GuardianJob::exec()
{
    cDebug() << "GuardianJob: starting guardian secret persistence…";

    Calamares::GlobalStorage* gs = Calamares::JobQueue::instance()->globalStorage();
    QString hashToPersist = m_hash;

    if ( hashToPersist.isEmpty() && gs && gs->contains( "guardianHash" ) )
    {
        hashToPersist = gs->value( "guardianHash" ).toString().trimmed();
    }

    if ( hashToPersist.isEmpty() )
    {
        QFile liveHash( QStringLiteral( "/run/parental-os/guardian.hash" ) );
        if ( liveHash.open( QIODevice::ReadOnly | QIODevice::Text ) )
        {
            hashToPersist = QString::fromUtf8( liveHash.readAll() ).trimmed();
            liveHash.close();
        }
    }

    if ( hashToPersist.isEmpty() )
    {
        cWarning() << "GuardianJob: no guardian hash found to persist!";
        return Calamares::JobResult::ok();
    }

    // Always update the live environment location
    writeSecureFile( QStringLiteral( "/run/parental-os/guardian.hash" ), hashToPersist );

    QString rootMountPoint = QStringLiteral( "/" );
    if ( gs && gs->contains( "rootMountPoint" ) )
    {
        rootMountPoint = gs->value( "rootMountPoint" ).toString();
    }

    if ( rootMountPoint.isEmpty() )
    {
        rootMountPoint = QStringLiteral( "/" );
    }

    const QString targetFilePath = QDir( rootMountPoint ).filePath( QStringLiteral( "etc/parental-os/guardian.hash" ) );
    cDebug() << "GuardianJob: writing guardian hash to" << targetFilePath;

    if ( !writeSecureFile( targetFilePath, hashToPersist ) )
    {
        return Calamares::JobResult::error(
            tr( "Failed to write guardian secret", "@error" ),
            tr( "Could not write %1." ).arg( targetFilePath ) );
    }

    cDebug() << "GuardianJob: successfully provisioned guardian secret.";
    return Calamares::JobResult::ok();
}
