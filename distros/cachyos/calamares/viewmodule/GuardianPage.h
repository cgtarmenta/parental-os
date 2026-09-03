/* === This file is part of Parental-OS ===
 *
 *   SPDX-FileCopyrightText: 2026 Parental-OS
 *   SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef GUARDIANPAGE_H
#define GUARDIANPAGE_H

#include <QWidget>

class QLineEdit;
class QLabel;

class GuardianPage : public QWidget
{
    Q_OBJECT

public:
    explicit GuardianPage( QWidget* parent = nullptr );
    ~GuardianPage() override = default;

    bool isValid() const;
    QString password() const;
    QString computedHash() const;

signals:
    void checkValidity();

private slots:
    void onTextChanged();

private:
    QLineEdit* m_passwordField = nullptr;
    QLineEdit* m_confirmField = nullptr;
    QLabel* m_statusLabel = nullptr;
    int m_minLength = 4;
};

#endif  // GUARDIANPAGE_H
