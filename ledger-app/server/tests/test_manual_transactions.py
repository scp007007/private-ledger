import uuid
import pytest
from app.db import connect
from test_api import api, HEADER, edit, transactions


def payload(**changes):
    return {'operation_id':str(uuid.uuid4()), 'transaction_id':str(uuid.uuid4()),
        'amount_cents':1234, 'direction':'expense', 'occurred_at':'2026-10-01T12:00:00+08:00',
        'merchant':'Synthetic shop','category':'Meals','note':'Synthetic note', **changes}


def test_manual_create_retry_edit_and_report(api):
    client, db = api
    body = payload()
    assert client.post('/api/v1/transactions',json=body).status_code == 401
    result = client.post('/api/v1/transactions',headers=HEADER,json=body)
    assert result.status_code == 200
    assert client.post('/api/v1/transactions',headers=HEADER,json=body).json() == result.json()
    assert len(transactions(client)['transactions']) == 1
    row = result.json()['transaction']
    assert row['source'] == 'manual'
    changed = edit(client,row,{'amount_cents':2345,'direction':'income','merchant':'Updated',
        'description':'Corrected','occurred_at':'2026-11-01T01:00:00+08:00'})
    assert changed.status_code == 200
    assert changed.json()['transaction']['version'] == 2
    october=client.get('/api/v1/reports/month?year=2026&month=10',headers=HEADER).json()
    november=client.get('/api/v1/reports/month?year=2026&month=11',headers=HEADER).json()
    assert october['total_actual_consumption_cents'] == 0
    assert november['total_income_cents'] == 2345
    assert edit(client,row,{'amount_cents':100}).status_code == 409
    assert client.post('/api/v1/transactions',headers=HEADER,json={**body,'note':'Different'}).status_code == 409
    assert client.post('/api/v1/transactions',headers=HEADER,json={**body,'operation_id':str(uuid.uuid4())}).status_code == 409


@pytest.mark.parametrize('changes',[{'amount_cents':0},{'amount_cents':1.5},{'direction':'other'},
    {'occurred_at':'2026-10-01T12:00:00'},{'amount_cents':None}])
def test_manual_invalid_values_never_create_rows(api,changes):
    client,_=api
    assert client.post('/api/v1/transactions',headers=HEADER,json=payload(**changes)).status_code == 422
    assert transactions(client)['transactions'] == []


def test_import_review_is_paginated_private_and_does_not_commit(api):
    client,_=api
    csv='occurred_at,amount,direction,merchant,external_id\n'+'\n'.join(
        f'2026-10-01,1.00,expense,Synthetic,fixture-{i}' for i in range(61))
    preview=client.post('/api/v1/imports/preview',headers=HEADER,data={'source':'generic'},
        files={'file':('fixture.csv',csv.encode(),'text/csv')}).json()
    url=f"/api/v1/imports/{preview['preview_id']}/rows"
    assert client.get(url).status_code == 401
    first=client.get(url,headers=HEADER).json()
    second=client.get(url+'?offset=50',headers=HEADER).json()
    assert len(first['rows']) == 50 and len(second['rows']) == 11
    assert first['total'] == 61
    assert all('raw_json' not in r and 'raw_data' not in r for r in first['rows'])
    assert transactions(client)['transactions'] == []
    assert client.get(url+'?limit=101',headers=HEADER).status_code == 422
    commit=client.post(f"/api/v1/imports/{preview['preview_id']}/commit",headers=HEADER)
    assert commit.json()['imported'] == 61
    assert client.get(url,headers=HEADER).status_code == 404


def test_edits_keep_raw_import_audit_and_reject_null(api):
    from test_api import import_csv
    client,db=api
    import_csv(client,'2026-10-01,12.00,expense,payment,Shop,Item,fixture-1')
    row=transactions(client)['transactions'][0]
    with connect(db) as connection:
        raw=connection.execute('SELECT raw_json FROM transactions').fetchone()[0]
    assert edit(client,row,{'amount_cents':None}).status_code == 422
    assert edit(client,row,{'amount_cents':2000}).status_code == 200
    with connect(db) as connection:
        assert connection.execute('SELECT raw_json FROM transactions').fetchone()[0] == raw
