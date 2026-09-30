import { useCallback, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

export type Role = 'system_admin' | 'deputy_admin' | 'line_manager' | 'player';

export interface Profile {
  user_id: string;
  email: string;
  role: Role;
  display_name?: string | null;
}

export interface SessionState {
  loading: boolean;
  session: Session | null;
  profile: Profile | null;
  /** Set when the account exists in auth but is not registered in the game. */
  rejected: boolean;
  /** Whatever the server actually said, so a plumbing fault is not reported as a
   *  permissions problem. */
  claimError: string | null;
  signOut: () => Promise<void>;
}

export function useSession(): SessionState {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [rejected, setRejected] = useState(false);
  const [claimError, setClaimError] = useState<string | null>(null);

  // Binds the Supabase auth user to its pre-registered game account and pays the
  // welcome grant. Safe to call on every load: the database makes it idempotent.
  const claim = useCallback(async (s: Session | null) => {
    if (!supabase || !s) {
      setProfile(null);
      setRejected(false);
      setClaimError(null);
      return;
    }
    const { data, error } = await supabase.rpc('claim_account');
    if (error) {
      setProfile(null);
      setRejected(true);
      // Surface the real cause. A missing function (PGRST202) or a denied grant
      // is an install problem, not an unregistered account, and saying so saves
      // an afternoon of looking in the wrong place.
      const code = error.code ? `${error.code}: ` : '';
      setClaimError(`${code}${error.message}`);
    } else {
      setProfile(data as Profile);
      setRejected(false);
      setClaimError(null);
    }
  }, []);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }
    let alive = true;

    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return;
      setSession(data.session);
      await claim(data.session);
      if (alive) setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, s) => {
      if (!alive) return;
      setSession(s);
      await claim(s);
    });

    return () => {
      alive = false;
      sub.subscription.unsubscribe();
    };
  }, [claim]);

  const signOut = useCallback(async () => {
    await supabase?.auth.signOut();
    setProfile(null);
    setRejected(false);
  }, []);

  return { loading, session, profile, rejected, claimError, signOut };
}
