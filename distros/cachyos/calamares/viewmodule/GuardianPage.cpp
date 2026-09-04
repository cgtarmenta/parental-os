/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "GuardianPage.h"

#include <QCryptographicHash>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QVBoxLayout>

GuardianPage::GuardianPage( QWidget* parent )
    : QWidget( parent )
{
    auto* mainLayout = new QVBoxLayout( this );
    mainLayout->setContentsMargins( 24, 24, 24, 24 );
    mainLayout->setSpacing( 16 );

    auto* titleLabel = new QLabel( tr( "Parental Guard — Clave de Guardián" ), this );
    QFont titleFont = titleLabel->font();
    titleFont.setPointSize( titleFont.pointSize() + 4 );
    titleFont.setBold( true );
    titleLabel->setFont( titleFont );
    mainLayout->addWidget( titleLabel );

    auto* descLabel = new QLabel(
        tr( "Configure la contraseña de Guardián para la administración del equipo y "
            "el desbloqueo remoto desde la aplicación de control parental en la red local." ),
        this );
    descLabel->setWordWrap( true );
    mainLayout->addWidget( descLabel );

    mainLayout->addSpacing( 12 );

    auto* formLayout = new QFormLayout();
    formLayout->setSpacing( 12 );

    m_passwordField = new QLineEdit( this );
    m_passwordField->setEchoMode( QLineEdit::Password );
    m_passwordField->setClearButtonEnabled( true );
    m_passwordField->setPlaceholderText( tr( "Ingrese al menos %1 caracteres" ).arg( m_minLength ) );

    m_confirmField = new QLineEdit( this );
    m_confirmField->setEchoMode( QLineEdit::Password );
    m_confirmField->setClearButtonEnabled( true );
    m_confirmField->setPlaceholderText( tr( "Repita la contraseña" ) );

    formLayout->addRow( tr( "Contraseña de Guardián:" ), m_passwordField );
    formLayout->addRow( tr( "Confirmar Contraseña:" ), m_confirmField );

    mainLayout->addLayout( formLayout );

    m_statusLabel = new QLabel( this );
    m_statusLabel->setStyleSheet( QStringLiteral( "color: #e06c75; font-weight: bold;" ) );
    mainLayout->addWidget( m_statusLabel );

    mainLayout->addStretch();

    connect( m_passwordField, &QLineEdit::textChanged, this, &GuardianPage::onTextChanged );
    connect( m_confirmField, &QLineEdit::textChanged, this, &GuardianPage::onTextChanged );

    onTextChanged();
}

void GuardianPage::onTextChanged()
{
    const QString p1 = m_passwordField->text();
    const QString p2 = m_confirmField->text();

    if ( p1.isEmpty() && p2.isEmpty() )
    {
        m_statusLabel->setText( tr( "Debe ingresar una contraseña de guardián." ) );
    }
    else if ( p1.length() < m_minLength )
    {
        m_statusLabel->setText( tr( "La contraseña debe tener al menos %1 caracteres." ).arg( m_minLength ) );
    }
    else if ( p1 != p2 )
    {
        m_statusLabel->setText( tr( "Las contraseñas no coinciden." ) );
    }
    else
    {
        m_statusLabel->setText( QString() );
    }

    emit checkValidity();
}

bool GuardianPage::isValid() const
{
    const QString p1 = m_passwordField->text();
    const QString p2 = m_confirmField->text();
    return ( !p1.isEmpty() && p1.length() >= m_minLength && p1 == p2 );
}

QString GuardianPage::password() const
{
    return m_passwordField->text();
}

QString GuardianPage::computedHash() const
{
    const QByteArray payload = QByteArrayLiteral( "parental-guard:lan-v1:" ) + m_passwordField->text().toUtf8();
    return QString::fromLatin1( QCryptographicHash::hash( payload, QCryptographicHash::Sha256 ).toHex().toLower() );
}
